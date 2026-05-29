#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy the Azure SRE Agent for the ai-observability-sre-demo.

.DESCRIPTION
    Steps performed:
      1. Register the Microsoft.SiteReliabilityEngineering provider.
      2. Grant the SRE Agent UAMI Reader + Monitoring Reader on the Resource Group
         (Reader = full visibility into all RG resources; Monitoring Reader = metric/log access).
      3. Create/update the SRE Agent resource (preview REST API).
      4. Attach the ADX connector (Database Viewer already set by Bicep).
      5. Attach the Azure Monitor connector.
      6. Attach GitHub connector (requires PAT — prompted if -GithubPat not supplied).
      7. Register Kusto tools (one per .kql file).
      8. Upload the system prompt (Instructions).

.PARAMETER GithubPat
    GitHub fine-grained PAT with Contents:Read + Metadata:Read on the repo.
    If omitted the script will prompt securely.

.PARAMETER GithubRepo
    GitHub repo URL. Default: https://github.com/kunalchandratre1/ai-observability-sre-demo

.PARAMETER MonitorScope
    Scope for the Azure Monitor connector.
    'rg'           = this resource group only (default, single-app demo).
    'subscription' = entire subscription (recommended for multi-RG distributed apps).
    You can also supply a full resource ID for a specific resource group in another subscription.

.NOTES
    Multi-resource group / distributed app guidance:
    - Set -MonitorScope subscription to give the SRE Agent visibility across ALL resource groups
      in the subscription without needing multiple Azure Monitor connectors.
    - Add additional ADX connectors by re-running the script with -AdxClusterName pointing to
      each ADX cluster (one connector per database).
    - Add additional GitHub connectors via portal for each additional repo.
    - No hard published limit on number of connectors per agent (preview as of May 2026).

.PARAMETER ResourceGroup
    Azure resource group name. Default: ai-obs-sre-demo

.PARAMETER Location
    Azure region. Default: australiaeast

.PARAMETER AgentName
    SRE Agent resource name. Default: aiosre-sre-agent-demo

.PARAMETER AdxClusterName
    ADX cluster name (without FQDN). Looked up automatically if not supplied.

.PARAMETER AdxDb
    ADX database name. Default: observability

.PARAMETER Subscription
    Azure subscription ID. Defaults to current az login subscription.

.EXAMPLE
    .\50-create-sre-agent.ps1
    .\50-create-sre-agent.ps1 -ResourceGroup my-rg -Location eastus
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup  = 'ai-obs-sre-demo',
    [string]$Location       = 'australiaeast',
    [string]$AgentName      = 'aiosre-sre-agent-demo',
    [string]$AdxClusterName = '',
    [string]$AdxDb          = 'observability',
    [string]$Subscription   = '',
    [string]$GithubPat      = '',
    [string]$GithubRepo     = 'https://github.com/kunalchandratre1/ai-observability-sre-demo',
    [ValidateSet('rg','subscription')]
    [string]$MonitorScope   = 'rg'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve working directory ──────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)   # infra/scripts -> infra -> repo root
$kqlDir    = Join-Path $repoRoot 'infra/sre-agent/kusto-tools'
$promptFile= Join-Path $repoRoot 'infra/sre-agent/prompts/system-prompt.md'

Write-Host "`n=== Azure SRE Agent Deployment ===" -ForegroundColor Cyan

# ── 0. Resolve subscription ────────────────────────────────────────────────────
if (-not $Subscription) {
    $Subscription = az account show --query id -o tsv 2>&1
}
Write-Host "Subscription : $Subscription"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "GitHub repo  : $GithubRepo"

# Prompt for PAT if not supplied
if (-not $GithubPat) {
    $securePat = Read-Host 'GitHub fine-grained PAT (Contents:Read + Metadata:Read)' -AsSecureString
    $GithubPat = [System.Net.NetworkCredential]::new('', $securePat).Password
}

$subPrefix = "https://management.azure.com/subscriptions/$Subscription"

# ── 1. Register provider ───────────────────────────────────────────────────────
Write-Host "`n[1/7] Registering Microsoft.SiteReliabilityEngineering provider..."
az provider register --namespace Microsoft.SiteReliabilityEngineering 2>&1 | Out-Null
# Also ensure the preview feature is registered
az feature register --namespace Microsoft.SiteReliabilityEngineering --name sreAgents 2>&1 | Out-Null
Write-Host "     Provider registration triggered (may take a few minutes to propagate)."

# ── 2. Resolve SRE UAMI ────────────────────────────────────────────────────────
Write-Host "`n[2/7] Resolving SRE Agent UAMI..."
$uamis = az identity list -g $ResourceGroup -o json 2>&1 | ConvertFrom-Json
$sreUami = $uamis | Where-Object { $_.name -like '*sre-uami*' } | Select-Object -First 1
if (-not $sreUami) {
    Write-Error "SRE UAMI not found in $ResourceGroup. Ensure Bicep (identity.bicep) has been deployed."
}
$sreUamiId          = $sreUami.id
$sreUamiPrincipalId = $sreUami.principalId
Write-Host "     SRE UAMI: $($sreUami.name)"
Write-Host "     Principal ID: $sreUamiPrincipalId"

# Grant Monitoring Reader on the RG (idempotent)
Write-Host "     Granting Monitoring Reader on RG..."
$rgId = az group show -n $ResourceGroup --query id -o tsv 2>&1

# Reader: full read access to all resources in the RG (ARM metadata, resource properties, configs)
$readerRoleId       = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
# Monitoring Reader: read access to monitoring data (metrics, logs, alerts, diagnostic settings)
$monReaderRoleId    = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

foreach ($roleId in @($readerRoleId, $monReaderRoleId)) {
    $roleName = if ($roleId -eq $readerRoleId) { 'Reader' } else { 'Monitoring Reader' }
    $existing = az role assignment list --assignee $sreUamiPrincipalId --role $roleId --scope $rgId -o json 2>&1 | ConvertFrom-Json
    if ($existing.Count -eq 0) {
        az role assignment create --assignee-object-id $sreUamiPrincipalId --assignee-principal-type ServicePrincipal `
            --role $roleId --scope $rgId -o none 2>&1
        Write-Host "     $roleName assigned on RG."
    } else {
        Write-Host "     $roleName already assigned on RG."
    }
}

# ── 3. Resolve ADX ────────────────────────────────────────────────────────────
Write-Host "`n[3/7] Resolving ADX cluster..."
if (-not $AdxClusterName) {
    $adxClusters = az kusto cluster list -g $ResourceGroup -o json 2>&1 | ConvertFrom-Json
    $AdxClusterName = ($adxClusters | Select-Object -First 1).name
}
$adxUri = "https://$AdxClusterName.$Location.kusto.windows.net"
Write-Host "     ADX cluster : $AdxClusterName"
Write-Host "     ADX URI     : $adxUri"
Write-Host "     ADX database: $AdxDb"
Write-Host "     (ADX Viewer role for SRE UAMI already set by adx.bicep principalAssignment)"

# ── 4. Create SRE Agent ───────────────────────────────────────────────────────
Write-Host "`n[4/7] Creating/updating SRE Agent '$AgentName'..."
$agentUrl = "$subPrefix/resourceGroups/$ResourceGroup/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$($AgentName)?api-version=2024-10-01-preview"

$agentBody = @{
    location = $Location
    identity = @{
        type = "UserAssigned"
        userAssignedIdentities = @{
            "$sreUamiId" = @{}
        }
    }
    properties = @{
        displayName = "AI Observability SRE Agent"
        description = "SRE Agent for ai-observability-sre-demo. Investigates AKS/APIM/Cosmos/OpenAI/Speech incidents using ADX telemetry + Managed Prometheus."
    }
} | ConvertTo-Json -Depth 10

$agentResult = az rest --method PUT --url $agentUrl --body $agentBody 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "SRE Agent PUT returned non-zero (preview API may differ per region). Raw response:"
    Write-Warning $agentResult
    Write-Warning "Continuing — some steps use the portal."
} else {
    $agent = $agentResult | ConvertFrom-Json
    Write-Host "     Agent state: $($agent.properties.provisioningState)"
}

# ── 5. Attach ADX connector ────────────────────────────────────────────────────
Write-Host "`n[5/7] Attaching ADX connector..."
$adxConnectorUrl = "$subPrefix/resourceGroups/$ResourceGroup/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$AgentName/connectors/adx-observability?api-version=2024-10-01-preview"
$adxConnectorBody = @{
    properties = @{
        connectorType = "AzureDataExplorer"
        connectionDetails = @{
            clusterUri  = $adxUri
            database    = $AdxDb
            authMode    = "ManagedIdentity"
            identityResourceId = $sreUamiId
        }
    }
} | ConvertTo-Json -Depth 10

$connResult = az rest --method PUT --url $adxConnectorUrl --body $adxConnectorBody 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "ADX connector PUT failed — complete via portal:"
    Write-Warning "  SRE Agent -> Connectors -> + Add -> Azure Data Explorer"
    Write-Warning "  Cluster: $adxUri  |  DB: $AdxDb  |  Auth: Managed Identity ($($sreUami.name))"
} else {
    Write-Host "     ADX connector attached."
}

# ── 6. Attach GitHub connector ───────────────────────────────────────────────
Write-Host "`n[6/8] Attaching GitHub connector..."
$ghConnectorUrl = "$subPrefix/resourceGroups/$ResourceGroup/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$AgentName/connectors/github-repo?api-version=2024-10-01-preview"
$ghConnectorBody = @{
    properties = @{
        connectorType = "GitHub"
        connectionDetails = @{
            repositoryUrl = $GithubRepo
            authMode      = "PersonalAccessToken"
            accessToken   = $GithubPat
        }
    }
} | ConvertTo-Json -Depth 10

$ghResult = az rest --method PUT --url $ghConnectorUrl --body $ghConnectorBody 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "GitHub connector PUT failed — complete via portal:"
    Write-Warning "  SRE Agent -> Connectors -> + Add -> GitHub"
    Write-Warning "  Repo: $GithubRepo"
    Write-Warning "  PAT : fine-grained, Contents:Read + Metadata:Read"
} else {
    Write-Host "     GitHub connector attached: $GithubRepo"
}

# ── 7. Attach Azure Monitor connector ─────────────────────────────────────────
Write-Host "`n[7/8] Attaching Azure Monitor connector..."
# Subscription scope covers ALL resource groups — recommended for distributed/multi-RG apps.
# RG scope covers only this resource group — sufficient for single-app demos.
$amScope = if ($MonitorScope -eq 'subscription') {
    "/subscriptions/$Subscription"
} else {
    "/subscriptions/$Subscription/resourceGroups/$ResourceGroup"
}
Write-Host "     Azure Monitor scope: $amScope"
$amwList = az resource list -g $ResourceGroup --resource-type 'Microsoft.Monitor/accounts' -o json 2>&1 | ConvertFrom-Json
$amwId   = ($amwList | Select-Object -First 1).id
$amConnectorUrl = "$subPrefix/resourceGroups/$ResourceGroup/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$AgentName/connectors/azure-monitor?api-version=2024-10-01-preview"
$amConnectorBody = @{
    properties = @{
        connectorType = "AzureMonitor"
        connectionDetails = @{
            scope    = $amScope
            authMode = "ManagedIdentity"
            identityResourceId = $sreUamiId
        }
    }
} | ConvertTo-Json -Depth 10

$amResult = az rest --method PUT --url $amConnectorUrl --body $amConnectorBody 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Azure Monitor connector PUT failed — complete via portal:"
    Write-Warning "  SRE Agent -> Connectors -> + Add -> Azure Monitor"
    Write-Warning "  Scope: RG $ResourceGroup  |  Auth: Managed Identity ($($sreUami.name))"
} else {
    Write-Host "     Azure Monitor connector attached."
}

# ── 7. Register Kusto tools ────────────────────────────────────────────────────
Write-Host "`n[8/8] Registering Kusto tools from $kqlDir ..."

$kqlFiles = Get-ChildItem -Path $kqlDir -Filter '*.kql'
foreach ($kqlFile in $kqlFiles) {
    $toolName = $kqlFile.BaseName
    $kqlText  = Get-Content $kqlFile.FullName -Raw

    # Parse declare query_parameters(...) to extract parameter definitions
    $paramBlock = ''
    if ($kqlText -match 'declare query_parameters\(([^)]+)\)') {
        $paramBlock = $Matches[1]
    }

    # Build parameters array from the declaration
    $toolParams = @()
    if ($paramBlock) {
        foreach ($paramDef in ($paramBlock -split ',')) {
            $paramDef = $paramDef.Trim()
            if ($paramDef -match '^(\w+):(\w+)(?:\s*=\s*(.+))?$') {
                $toolParams += @{
                    name         = $Matches[1]
                    type         = $Matches[2]
                    defaultValue = if ($Matches[3]) { $Matches[3].Trim().Trim('"') } else { $null }
                }
            }
        }
    }

    $toolUrl = "$subPrefix/resourceGroups/$ResourceGroup/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$AgentName/tools/$($toolName)?api-version=2024-10-01-preview"
    $toolBody = @{
        properties = @{
            toolType    = "KustoQuery"
            displayName = $toolName
            description = (($kqlText -split "`n") | Where-Object { $_ -match '^//' } | Select-Object -First 2 | ForEach-Object { $_ -replace '^//\s*', '' }) -join ' '
            connectionDetails = @{
                connectorName = "adx-observability"
                query         = $kqlText
                parameters    = $toolParams
            }
        }
    } | ConvertTo-Json -Depth 10

    $toolResult = az rest --method PUT --url $toolUrl --body $toolBody 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Tool '$toolName' failed via API — upload manually via portal (SRE Agent -> Tools -> + Add KQL)."
    } else {
        Write-Host "     Registered tool: $toolName"
    }
}

# ── 8. Upload system prompt ───────────────────────────────────────────────────
Write-Host "`nUploading system prompt..."
$systemPrompt = Get-Content $promptFile -Raw
$promptUrl = "$subPrefix/resourceGroups/$ResourceGroup/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$AgentName/instructions/default?api-version=2024-10-01-preview"
$promptBody = @{
    properties = @{
        content = $systemPrompt
    }
} | ConvertTo-Json -Depth 5

$promptResult = az rest --method PUT --url $promptUrl --body $promptBody 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "System prompt upload failed via API — paste manually:"
    Write-Warning "  SRE Agent -> Instructions -> paste contents of:"
    Write-Warning "  $promptFile"
} else {
    Write-Host "  System prompt uploaded."
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " SRE Agent deployment complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Agent name  : $AgentName"
Write-Host "ADX         : $adxUri / $AdxDb"
Write-Host "UAMI        : $($sreUami.name)"
Write-Host ""
Write-Host "REMAINING MANUAL STEPS:" -ForegroundColor Yellow
Write-Host " 1. Smoke test — ask the agent:"
Write-Host "    'Show me the most recent application errors in the last 30 minutes.'"
Write-Host "    Expected: agent calls QueryRecentAppErrors(30m, 'api-service') and returns structured RCA."
Write-Host ""
Write-Host " 2. If any connector/tool step failed above, see portal fallback instructions in:"
Write-Host "    docs/runbooks/sre-agent-setup.md"
Write-Host ""
Write-Host "WHAT THE SRE AGENT CAN SEE:" -ForegroundColor Cyan
Write-Host " - All Azure resources in RG '$ResourceGroup' (Reader)"
Write-Host " - All metrics, logs, alerts in RG (Monitoring Reader)"
Write-Host " - ADX 'observability' database — AppLogs, AppSpans, AppExceptions, APIMGatewayLogs"
Write-Host " - Azure Monitor scope: $amScope"
Write-Host " - GitHub repo source code: $GithubRepo"
Write-Host ""
Write-Host "MULTI-RG / DISTRIBUTED APP TIPS:" -ForegroundColor Cyan
Write-Host " - Re-run with -MonitorScope subscription to see ALL resource groups in sub $Subscription"
Write-Host " - Re-run with -AdxClusterName <other-cluster> to add a second ADX connector"
Write-Host " - Add more repos via portal: SRE Agent -> Connectors -> + Add -> GitHub"
Write-Host " - Grant the SRE UAMI 'Reader' on each additional RG:"
Write-Host "   az role assignment create --assignee $sreUamiPrincipalId --role Reader --scope /subscriptions/$Subscription/resourceGroups/<other-rg>"

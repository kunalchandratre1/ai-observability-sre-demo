#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Imports Grafana datasources (ADX, Azure Monitor) and
    all dashboard JSON files from infra/grafana/dashboards/.
    Safe to re-run — datasources and dashboards use upsert/overwrite.

.PARAMETER ResourceGroup
    Azure resource group (default: ai-obs-sre-demo)

.EXAMPLE
    .\40-import-grafana.ps1
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ai-obs-sre-demo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rg = $ResourceGroup

Write-Host ""
Write-Host "=== [0/3] Resolving Azure resource values ==="

$grafanaName = (az grafana list -g $rg -o json | ConvertFrom-Json)[0].name
$grafanaHost = az grafana show -g $rg -n $grafanaName --query properties.endpoint -o tsv
$grafanaHost = $grafanaHost.TrimEnd('/')

$adxCluster  = (az kusto cluster list -g $rg -o json | ConvertFrom-Json)[0].name
# Use the cluster's own URI — avoids location display-name vs slug mismatch ("Australia East" vs "australiaeast")
$adxUri      = (az kusto cluster show -g $rg -n $adxCluster --query uri -o tsv).TrimEnd('/')
$grafanaMsiId = az grafana show -g $rg -n $grafanaName --query identity.principalId -o tsv
$adxDb       = 'observability'

$subId       = az account show --query id -o tsv
$tenantId    = az account show --query tenantId -o tsv

# Resolve Log Analytics workspace (for Container Insights panels in D1)
# Prefer the app+PaaS LAW (aiosre-la-demo) over the SRE Agent backing LAW (aiosre-law-demo)
$lawList     = az monitor log-analytics workspace list -g $rg -o json | ConvertFrom-Json
$lawName     = ($lawList | Where-Object { $_.name -like '*-la-*' } | Select-Object -First 1)
if (-not $lawName) { $lawName = $lawList | Select-Object -First 1 }
$lawResourceId = $lawName.id

Write-Host "  Grafana      : $grafanaHost"
Write-Host "  ADX URI      : $adxUri"
Write-Host "  LAW          : $($lawName.name)"

# ── Ensure Grafana Admin role for current user (idempotent) ──────────────────
Write-Host ""
Write-Host "=== [0b/3] Ensuring current user has Grafana Admin role ==="
$grafanaResourceId = az grafana show -g $rg -n $grafanaName --query id -o tsv
$currentOid = az account show --query id -o tsv  # subscription id used as fallback
$currentOid = 'bf41e426-aa10-40c5-a893-118908206a75'  # injected by deploy — current user OID
az role assignment create --role "Grafana Admin" --assignee $currentOid --scope $grafanaResourceId 2>&1 | Out-Null
Write-Host "  Grafana Admin role ensured."

# ── [1/3] Datasources via az grafana CLI ──────────────────────────────────────
Write-Host ""
Write-Host "=== [1/3] Creating/updating Grafana datasources ==="

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ADX datasource
$dsAdx = @{
    name       = 'ADX'
    type       = 'grafana-azure-data-explorer-datasource'
    access     = 'proxy'
    isDefault  = $false
    jsonData   = @{ clusterUrl = $adxUri; defaultDatabase = $adxDb; azureCredentials = @{ authType = 'msi' } }
    secureJsonData = @{}
}
$dsAdxJson = $dsAdx | ConvertTo-Json -Depth 5 -Compress
$tmpDs = [System.IO.Path]::GetTempFileName() + '.json'
$dsAdxJson | Set-Content $tmpDs -Encoding utf8
# Delete existing if present (upsert workaround)
az grafana data-source delete -n $grafanaName --data-source 'ADX' 2>$null | Out-Null
az grafana data-source create -n $grafanaName --definition "@$tmpDs" 2>&1 | Out-Null
Remove-Item $tmpDs -ErrorAction SilentlyContinue
# Resolve the actual UID assigned by Grafana (changes every time datasource is recreated)
$adxDsUid = (az grafana data-source list -n $grafanaName -o json | ConvertFrom-Json | Where-Object { $_.name -eq 'ADX' }).uid
Write-Host "  ADX datasource: done (uid=$adxDsUid)."

# Grant Grafana MSI Viewer access on ADX observability database (idempotent)
Write-Host ""
Write-Host "=== [1b/3] Granting Grafana MSI Viewer access on ADX database ==="
az kusto database add-principal --cluster-name $adxCluster --database-name observability --resource-group $rg --value name="grafana-msi" type="App" app-id="$grafanaMsiId" email="" fqn="" role="Viewer" -o none 2>&1 | Out-Null
Write-Host "  ADX Viewer granted to Grafana MSI ($grafanaMsiId)." -ForegroundColor Green

# Azure Monitor datasource (usually pre-created by AMG, just verify)
$existingDs = az grafana data-source list -n $grafanaName -o json 2>&1 | ConvertFrom-Json
$azmonExists = $existingDs | Where-Object { $_.type -eq 'grafana-azure-monitor-datasource' }
if (-not $azmonExists) {
    $dsAzMon = @{
        name      = 'AzureMonitor'
        type      = 'grafana-azure-monitor-datasource'
        access    = 'proxy'
        isDefault = $true
        jsonData  = @{ subscriptionId = $subId; azureAuthType = 'msi' }
        secureJsonData = @{}
    }
    $dsAzMonJson = $dsAzMon | ConvertTo-Json -Depth 5 -Compress
    $tmpDs2 = [System.IO.Path]::GetTempFileName() + '.json'
    $dsAzMonJson | Set-Content $tmpDs2 -Encoding utf8
    az grafana data-source create -n $grafanaName --definition "@$tmpDs2" 2>&1 | Out-Null
    Remove-Item $tmpDs2 -ErrorAction SilentlyContinue
    Write-Host "  AzureMonitor datasource: created."
} else {
    Write-Host "  AzureMonitor datasource: already exists."
}

# ── [2/3] Dashboards via az grafana CLI ───────────────────────────────────────
Write-Host ""
Write-Host "=== [2/3] Importing Grafana dashboards ==="

$DashboardsDir = Resolve-Path (Join-Path $ScriptDir '../grafana/dashboards')

$dashboards = Get-ChildItem $DashboardsDir -Filter '*.json' | Sort-Object Name
foreach ($f in $dashboards) {
    # Template-substitute dashboard placeholders with live resource IDs
    $dashJson = Get-Content $f.FullName -Raw -Encoding utf8
    $dashJson = $dashJson -replace '\{\{LAW_RESOURCE_ID\}\}', $lawResourceId
    $dashJson = $dashJson -replace '\{\{SUBSCRIPTION_ID\}\}', $subId
    $dashJson = $dashJson -replace '\{\{TENANT_ID\}\}', $tenantId
    $dashJson = $dashJson -replace '\{\{ADX_DS_UID\}\}', $adxDsUid

    $tmpDash = [System.IO.Path]::GetTempFileName() + '.json'
    $dashJson | Set-Content $tmpDash -Encoding utf8

    $result = az grafana dashboard import -n $grafanaName --definition $tmpDash --overwrite 2>&1 | ConvertFrom-Json
    $status = if ($result.status) { $result.status } else { 'ok' }
    Write-Host "  $($f.Name): $status"
    Remove-Item $tmpDash -ErrorAction SilentlyContinue
}

# ── [3/3] Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Grafana import complete."
Write-Host "  URL: $grafanaHost"
Write-Host "  Dashboards imported: $($dashboards.Count)"
Write-Host ""
Write-Host "Next step  ->  .\50-create-sre-agent.ps1"

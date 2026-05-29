#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Purge soft-deleted Azure resources before redeployment.
    Run this BEFORE 10-deploy-bicep.sh / the Bicep az deployment group create command.

.DESCRIPTION
    Resources with soft-delete that block redeployment:
      - Key Vault          : VaultAlreadyExists / Conflict
      - Azure OpenAI       : CustomDomainInUse / AccountExists
      - Azure Speech       : CustomDomainInUse / AccountExists
      - Azure APIM         : ServiceAlreadyExists (soft-delete in Developer/Premium SKUs)
      - Azure Firewall     : No soft-delete, but SKU changes require explicit delete first

    This script:
      1. Purges soft-deleted Key Vaults matching the demo naming pattern.
      2. Purges soft-deleted Cognitive Services accounts (OpenAI + Speech).
      3. Purges soft-deleted APIM instances.
      4. Optionally hard-deletes the existing Azure Firewall (needed when changing firewall SKU).

.PARAMETER ResourceGroup
    Azure resource group. Default: ai-obs-sre-demo

.PARAMETER Location
    Azure region. Default: australiaeast

.PARAMETER Prefix
    Resource name prefix used in Bicep. Default: aiosre

.PARAMETER Env
    Environment tag. Default: demo

.PARAMETER DeleteFirewall
    Switch. Pass to delete the existing firewall (required when changing firewall SKU e.g. Standard -> Basic).
    WARNING: This deletes the firewall — Bicep will recreate it on next deploy.

.EXAMPLE
    # Normal redeploy prep (KV + OpenAI + Speech + APIM purge):
    .\05-purge-soft-deleted.ps1

    # When also changing firewall SKU:
    .\05-purge-soft-deleted.ps1 -DeleteFirewall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroup  = 'ai-obs-sre-demo',
    [string]$Location       = 'australiaeast',
    [string]$Prefix         = 'aiosre',
    [string]$Env            = 'demo',
    [switch]$DeleteFirewall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # Continue on individual purge failures

Write-Host "`n=== Pre-Deploy Purge Script ===" -ForegroundColor Cyan
Write-Host "Resource Group : $ResourceGroup"
Write-Host "Location       : $Location"
Write-Host "Prefix/Env     : $Prefix / $Env"
Write-Host ""

# ── Helper ────────────────────────────────────────────────────────────────────
function Invoke-Purge([string]$Label, [scriptblock]$Action) {
    Write-Host "  Purging $Label..." -NoNewline
    try {
        & $Action 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host " done." -ForegroundColor Green }
        else                     { Write-Host " skipped/already gone." -ForegroundColor DarkGray }
    } catch {
        Write-Host " error: $_" -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. KEY VAULT — purge soft-deleted vaults
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[1/4] Key Vault soft-deleted purge..." -ForegroundColor Yellow

$deletedKvs = az keyvault list-deleted --query "[].{name:name, location:properties.location}" -o json 2>&1 | ConvertFrom-Json
$demoKvs = $deletedKvs | Where-Object { $_.name -like "${Prefix}kv${Env}*" }

if ($demoKvs) {
    foreach ($kv in $demoKvs) {
        Invoke-Purge "Key Vault '$($kv.name)' in '$($kv.location)'" {
            az keyvault purge --name $kv.name --location $kv.location
        }
    }
} else {
    Write-Host "  No soft-deleted Key Vaults found matching '${Prefix}kv${Env}*'." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. COGNITIVE SERVICES — purge soft-deleted OpenAI + Speech accounts
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n[2/4] Cognitive Services (OpenAI + Speech) soft-deleted purge..." -ForegroundColor Yellow

# Names are deterministic (no uniqueString), so we know exactly what to look for:
$csNames = @(
    "${Prefix}-openai-${Env}"
    "${Prefix}-speech-${Env}"
)

# List all soft-deleted cognitive services accounts in the subscription
$deletedCs = az rest --method GET `
    --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.CognitiveServices/deletedAccounts?api-version=2024-10-01" `
    -o json 2>&1 | ConvertFrom-Json

if ($deletedCs -and $deletedCs.value) {
    foreach ($name in $csNames) {
        $match = $deletedCs.value | Where-Object { $_.name -eq $name }
        if ($match) {
            $csLocation = $match.location
            $subId = (az account show --query id -o tsv 2>&1)
            Invoke-Purge "CognitiveServices '$name' in '$csLocation'" {
                az rest --method DELETE `
                    --url "https://management.azure.com/subscriptions/$subId/providers/Microsoft.CognitiveServices/locations/$csLocation/resourceGroups/$ResourceGroup/deletedAccounts/${name}?api-version=2024-10-01" `
                    2>&1 | Out-Null
            }
        } else {
            Write-Host "  '$name': no soft-deleted record found." -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "  No soft-deleted Cognitive Services accounts found in subscription." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. APIM — purge soft-deleted instance
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n[3/4] APIM soft-deleted purge..." -ForegroundColor Yellow

$apimName = "${Prefix}-apim-${Env}"
$subId    = (az account show --query id -o tsv 2>&1)

$deletedApim = az rest --method GET `
    --url "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ApiManagement/deletedservices?api-version=2024-05-01" `
    -o json 2>&1 | ConvertFrom-Json

if ($deletedApim -and $deletedApim.value) {
    $apimMatch = $deletedApim.value | Where-Object { $_.name -eq $apimName }
    if ($apimMatch) {
        $apimLocation = $apimMatch.location
        Invoke-Purge "APIM '$apimName' in '$apimLocation'" {
            az rest --method DELETE `
                --url "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ApiManagement/locations/$apimLocation/deletedservices/${apimName}?api-version=2024-05-01" `
                2>&1 | Out-Null
        }
        Write-Host "  Note: APIM purge can take 10-15 minutes to propagate." -ForegroundColor DarkYellow
    } else {
        Write-Host "  '$apimName': no soft-deleted record found." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  No soft-deleted APIM instances found." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. AZURE FIREWALL — hard delete (no soft-delete; needed for SKU changes)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n[4/4] Azure Firewall..." -ForegroundColor Yellow

$fwName = "${Prefix}-fw-${Env}"
$fwExists = az network firewall show -g $ResourceGroup -n $fwName --query name -o tsv 2>&1

if ($fwExists -and $fwExists -notmatch 'not found|ERROR|error') {
    if ($DeleteFirewall) {
        if ($PSCmdlet.ShouldProcess("$fwName in $ResourceGroup", "DELETE Azure Firewall")) {
            Write-Host "  Deleting firewall '$fwName' (required for SKU change)..." -ForegroundColor Yellow
            az network firewall delete -g $ResourceGroup -n $fwName --no-wait
            Write-Host "  Firewall delete triggered (async). Wait ~5 min before running Bicep deploy." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  Firewall '$fwName' exists. Pass -DeleteFirewall if you are changing firewall SKU." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Firewall '$fwName': not found or already deleted." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Purge complete. Safe to redeploy." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next step — run Bicep deploy (r12+):"
Write-Host @'
  $rg='ai-obs-sre-demo'; $name="main-$(Get-Date -Format yyyyMMddHHmmss)"
  az deployment group create --resource-group $rg --name $name `
    --template-file 'infra/bicep/main.bicep' `
    --parameters 'infra/bicep/main.parameters.example.json' `
    --parameters location='australiaeast' deployerObjectId='<your-object-id>' `
      aksNodeSku='Standard_B2s' aksSystemNodeSku='Standard_B2s' `
      adxSku='Dev(No SLA)_Standard_D11_v2' adxCapacity=1 `
      firewallSku='Basic' deploymentSuffix='r12' onPremVmPassword='<password>'
'@

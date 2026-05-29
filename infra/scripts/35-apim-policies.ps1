#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Applies APIM inbound-correlation and diagnostics policies to the voice-orders API.
    Safe to re-run (idempotent).

.PARAMETER ResourceGroup
    Azure resource group (default: ai-obs-sre-demo)

.EXAMPLE
    .\35-apim-policies.ps1
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ai-obs-sre-demo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rg = $ResourceGroup

Write-Host ""
Write-Host "=== [0/2] Resolving APIM ==="
$apim  = (az apim list -g $rg -o json | ConvertFrom-Json)[0].name
$subId = az account show --query id -o tsv
Write-Host "  APIM: $apim"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$PoliciesDir = Resolve-Path (Join-Path $ScriptDir '../apim/policies')

# ── [1/2] Inbound correlation policy ─────────────────────────────────────────
Write-Host ""
Write-Host "=== [1/2] Applying inbound-correlation policy to voice-orders API ==="
$policyXml = Get-Content "$PoliciesDir/inbound-correlation.xml" -Raw
az apim api policy create-or-update `
    -g $rg --service-name $apim --api-id voice-orders `
    --policy-content $policyXml `
    --policy-format xml 2>&1 | Select-Object -Last 2
Write-Host "  Inbound correlation policy applied."

# ── [2/2] Diagnostics to Event Hub ───────────────────────────────────────────
Write-Host ""
Write-Host "=== [2/2] Applying APIM diagnostics settings ==="
$diagFile = Join-Path $ScriptDir 'diagnostic-settings.json'
if (Test-Path $diagFile) {
    az rest --method put `
        --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/apis/voice-orders/diagnostics/applicationinsights?api-version=2023-09-01-preview" `
        --body "@$diagFile" 2>&1 | Select-Object -Last 2
    Write-Host "  Diagnostics settings applied."
} else {
    Write-Warning "  diagnostic-settings.json not found at $diagFile — skipping diagnostics."
}

Write-Host ""
Write-Host "APIM policies applied."
Write-Host "  APIM gateway: https://$apim.azure-api.net"
Write-Host ""
Write-Host "Next step  ->  .\40-import-grafana.ps1"

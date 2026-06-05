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
# Read bytes and strip UTF-8 BOM (EF BB BF) — az CLI Python cannot encode \ufeff on Windows.
# Use Invoke-RestMethod (PowerShell native) to avoid az CLI's charmap encoding limitation.
$policyBytes = [System.IO.File]::ReadAllBytes("$PoliciesDir/inbound-correlation.xml")
if ($policyBytes[0] -eq 0xEF -and $policyBytes[1] -eq 0xBB -and $policyBytes[2] -eq 0xBF) {
    $policyBytes = $policyBytes[3..($policyBytes.Length - 1)]
}
$policyXml  = [System.Text.Encoding]::UTF8.GetString($policyBytes)
$policyBody = [System.Text.Encoding]::UTF8.GetBytes(
    (@{ properties = @{ format = 'xml'; value = $policyXml } } | ConvertTo-Json -Depth 5 -Compress)
)
$token   = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$policyUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/apis/voice-orders/policies/policy?api-version=2023-09-01-preview"
Invoke-RestMethod -Method PUT -Uri $policyUrl -Headers $headers -Body $policyBody | Out-Null
Write-Host "  Inbound correlation policy applied." -ForegroundColor Green

# ── [2/2] Azure Monitor Diagnostic Settings on APIM service ──────────────────
# Note: APIM API-level diagnostics only accept Application Insights or
# azuremonitor loggers. Event Hub logging is handled by the log-to-eventhub
# policy element already embedded in inbound-correlation.xml (step [1/2]).
# Here we enable the azuremonitor diagnostic on the API so platform metrics flow.
# httpCorrelationProtocol is only valid for Application Insights diagnostics.
Write-Host ""
Write-Host "=== [2/2] Enabling Azure Monitor diagnostic on voice-orders API ==="
$diagBodyStr = '{"properties":{"loggerId":"/loggers/azuremonitor","alwaysLog":"allErrors","verbosity":"information","logClientIp":true}}'
$tmpDiag = [System.IO.Path]::GetTempFileName() + '.json'
$diagBodyStr | Set-Content $tmpDiag -Encoding utf8
az rest --method PUT `
    --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/apis/voice-orders/diagnostics/azuremonitor?api-version=2023-09-01-preview" `
    --body "@$tmpDiag" --output none 2>&1 | Select-Object -Last 2
Remove-Item $tmpDiag -ErrorAction SilentlyContinue
Write-Host "  Azure Monitor diagnostic enabled."

Write-Host ""
Write-Host "APIM policies applied."
Write-Host "  APIM gateway: https://$apim.azure-api.net"
Write-Host ""
Write-Host "Next step  ->  .\40-import-grafana.ps1"

#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys the static UI to Azure Storage (static website).
    Resolves APIM gateway URL and Grafana URL from the deployed resources,
    bakes them into app.js as default values, then uploads all files to the
    $web container so the app is immediately usable without manual configuration.

.PARAMETER ResourceGroup
    Azure resource group. Default: ai-obs-sre-demo

.EXAMPLE
    .\45-deploy-ui.ps1
    .\45-deploy-ui.ps1 -ResourceGroup my-rg
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ai-obs-sre-demo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$UiDir      = Resolve-Path (Join-Path $ScriptDir '..\..\ui\public')
$rg         = $ResourceGroup

Write-Host ""
Write-Host "=== [1/4] Resolving Azure resource endpoints ==="

# Storage account (UI hosting)
$storageAcct = (az storage account list -g $rg -o json | ConvertFrom-Json |
    Where-Object { $_.name -like '*ui*' } | Select-Object -First 1).name
if (-not $storageAcct) {
    Write-Error "UI storage account not found in $rg. Ensure Bicep (uistorage.bicep) has been deployed."
}
Write-Host "  Storage account : $storageAcct"

# Enable static website on the storage account (idempotent)
az storage blob service-properties update `
    --account-name $storageAcct `
    --static-website `
    --index-document index.html `
    --404-document index.html `
    --auth-mode login `
    -o none
Write-Host "  Static website  : enabled"

$uiUrl = az storage account show -n $storageAcct -g $rg `
    --query "primaryEndpoints.web" -o tsv
Write-Host "  UI URL          : $uiUrl"

# APIM gateway URL
$apimGwUrl = (az apim list -g $rg -o json | ConvertFrom-Json)[0].properties.gatewayUrl
Write-Host "  APIM gateway    : $apimGwUrl"

# APIM subscription key (first non-built-in subscription, primary key)
$apimName = (az apim list -g $rg -o json | ConvertFrom-Json)[0].name
$apimKey = az apim subscription list -g $rg --service-name $apimName `
    --query "[?contains(name,'voice') || contains(name,'demo')].primaryKey | [0]" -o tsv 2>$null
if (-not $apimKey) {
    # Fallback: grab first non-master subscription key
    $apimKey = az apim subscription list -g $rg --service-name $apimName `
        --query "[?name != 'master'].primaryKey | [0]" -o tsv 2>$null
}
Write-Host "  APIM key        : $(if ($apimKey) { $apimKey.Substring(0,[Math]::Min(8,$apimKey.Length)) + '...' } else { '(not found - enter manually in UI)' })"

# Grafana URL
$grafanaUrl = (az grafana list -g $rg -o json | ConvertFrom-Json)[0].properties.endpoint
$grafanaUrl = $grafanaUrl.TrimEnd('/')
Write-Host "  Grafana         : $grafanaUrl"

Write-Host ""
Write-Host "=== [2/4] Patching app.js with live endpoint defaults ==="

# Read the original app.js
$appJsSrc = Get-Content (Join-Path $UiDir 'app.js') -Raw -Encoding utf8

# Replace placeholder constants at the top of app.js
# The app.js has DEFAULT_APIM_URL and DEFAULT_GRAFANA_URL constants
$appJsPatched = $appJsSrc `
    -replace "(?m)^const DEFAULT_APIM_URL\s*=\s*'[^']*';", "const DEFAULT_APIM_URL = '$apimGwUrl';" `
    -replace "(?m)^const DEFAULT_GRAFANA_URL\s*=\s*'[^']*';", "const DEFAULT_GRAFANA_URL = '$grafanaUrl';"

# Write to a temp file (don't overwrite original source)
$tmpDir   = Join-Path ([System.IO.Path]::GetTempPath()) "sre-ui-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmpDir | Out-Null

# Copy all UI files to temp
Copy-Item (Join-Path $UiDir '*') $tmpDir -Recurse
# Overwrite app.js with patched version
$appJsPatched | Set-Content (Join-Path $tmpDir 'app.js') -Encoding utf8

Write-Host "  Defaults baked : APIM=$apimGwUrl"
Write-Host "  Defaults baked : Grafana=$grafanaUrl"

Write-Host ""
Write-Host "=== [3/4] Uploading UI files to Azure Storage \$web container ==="

az storage blob upload-batch `
    --account-name $storageAcct `
    --source $tmpDir `
    --destination '$web' `
    --overwrite `
    --auth-mode login `
    --content-cache-control 'no-cache' `
    -o none

Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Upload complete."

Write-Host ""
Write-Host "=== [4/4] Summary ==="
Write-Host ""
Write-Host "  UI is live at: $uiUrl" -ForegroundColor Green
Write-Host ""
Write-Host "  The UI is pre-configured with:"
Write-Host "    APIM gateway : $apimGwUrl"
if ($apimKey) {
    Write-Host "    APIM key     : $($apimKey.Substring(0,[Math]::Min(8,$apimKey.Length)))... (stored in browser localStorage)"
}
Write-Host "    Grafana      : $grafanaUrl"
Write-Host ""
Write-Host "  Open the URL above in a browser to start the demo."
Write-Host "  Next step -> complete SRE Agent portal setup per docs/runbooks/sre-agent-setup.md"

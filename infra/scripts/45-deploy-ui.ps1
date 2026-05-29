#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys the static UI to Azure App Service (Free F1).
    Creates the App Service if it doesn't exist, resolves APIM gateway URL
    and Grafana URL from deployed resources, bakes them into app.js, then
    deploys all files via zip deploy so the app is immediately usable.

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

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$UiDir       = Resolve-Path (Join-Path $ScriptDir '..\..\ui\public')
$rg          = $ResourceGroup
$webAppName  = 'aiosre-ui-demo'
$planName    = 'aiosre-ui-plan-demo'

Write-Host ""
Write-Host "=== [1/5] Resolving Azure resource endpoints ==="

# ---- App Service: create if not present -----------------------------------
$appExists = az webapp show -g $rg -n $webAppName --query "name" -o tsv 2>$null
if (-not $appExists) {
    Write-Host "  App Service not found — creating '$webAppName' (Free F1)..."
    $loc = az group show -n $rg --query location -o tsv

    # App Service Plan
    $planExists = az appservice plan show -g $rg -n $planName --query "name" -o tsv 2>$null
    if (-not $planExists) {
        az appservice plan create -g $rg -n $planName --location $loc --sku F1 -o none
        Write-Host "  App Service Plan '$planName' created."
    }

    # Web App
    az webapp create -g $rg -p $planName -n $webAppName -o none
    Write-Host "  Web App '$webAppName' created."
} else {
    Write-Host "  App Service     : $webAppName (exists)"
}

$uiUrl = "https://$webAppName.azurewebsites.net"
Write-Host "  UI URL          : $uiUrl"

# ---- APIM -----------------------------------------------------------------
$apimObj   = az apim list -g $rg -o json | ConvertFrom-Json
$apimObj   = if ($apimObj -is [array]) { $apimObj[0] } else { $apimObj }
$apimName  = $apimObj.name
$apimGwUrl = $apimObj.gatewayUrl
if (-not $apimGwUrl) {
    $apimGwUrl = az apim show -g $rg -n $apimName --query "gatewayUrl" -o tsv 2>$null
}
Write-Host "  APIM gateway    : $apimGwUrl"

# APIM subscription key (built-in master subscription)
$subId = az account show --query id -o tsv
$apimKey = az rest --method post `
    --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/master/listSecrets?api-version=2022-08-01" `
    --query "primaryKey" -o tsv 2>$null
Write-Host "  APIM key        : $(if ($apimKey) { $apimKey.Substring(0,[Math]::Min(8,$apimKey.Length)) + '...' } else { '(not found - enter manually in UI)' })"

# ---- Grafana ---------------------------------------------------------------
$grafanaObj = az grafana list -g $rg -o json | ConvertFrom-Json
$grafanaObj = if ($grafanaObj -is [array]) { $grafanaObj[0] } else { $grafanaObj }
$grafanaUrl = $grafanaObj.properties.endpoint.TrimEnd('/')
Write-Host "  Grafana         : $grafanaUrl"

Write-Host ""
Write-Host "=== [2/5] Patching app.js with live endpoint defaults ==="

$appJsSrc = Get-Content (Join-Path $UiDir 'app.js') -Raw -Encoding utf8
$appJsPatched = $appJsSrc `
    -replace "(?m)^const DEFAULT_APIM_URL\s*=\s*'[^']*';",     "const DEFAULT_APIM_URL = '$apimGwUrl';" `
    -replace "(?m)^const DEFAULT_GRAFANA_URL\s*=\s*'[^']*';",  "const DEFAULT_GRAFANA_URL = '$grafanaUrl';"
Write-Host "  Defaults baked : APIM=$apimGwUrl"
Write-Host "  Defaults baked : Grafana=$grafanaUrl"

Write-Host ""
Write-Host "=== [3/5] Preparing deployment package ==="

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "sre-ui-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmpDir | Out-Null

# Copy all UI files (includes index.html, styles.css, web.config)
Copy-Item (Join-Path $UiDir '*') $tmpDir -Recurse
# Overwrite app.js with patched version
$appJsPatched | Set-Content (Join-Path $tmpDir 'app.js') -Encoding utf8

# Zip contents (files at root, not in a subfolder)
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "sre-ui-$(Get-Random).zip"
Push-Location $tmpDir
Compress-Archive -Path * -DestinationPath $zipPath -Force
Pop-Location
Write-Host "  Package         : $zipPath"

Write-Host ""
Write-Host "=== [4/5] Deploying to App Service '$webAppName' ==="

az webapp deployment source config-zip `
    --resource-group $rg `
    --name $webAppName `
    --src $zipPath `
    -o none

Remove-Item $tmpDir  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force   -ErrorAction SilentlyContinue
Write-Host "  Deployment complete."

Write-Host ""
Write-Host "=== [5/5] Summary ==="
Write-Host ""
Write-Host "  UI is live at  : $uiUrl" -ForegroundColor Green
Write-Host ""
Write-Host "  Pre-configured with:"
Write-Host "    APIM gateway : $apimGwUrl"
if ($apimKey) {
    Write-Host "    APIM key     : $($apimKey.Substring(0,[Math]::Min(8,$apimKey.Length)))... (auto-set in browser localStorage)"
}
Write-Host "    Grafana      : $grafanaUrl"
Write-Host ""
Write-Host "  Open the URL above in a browser to start the demo."
Write-Host "  Next -> complete SRE Agent portal setup per docs/runbooks/sre-agent-setup.md"

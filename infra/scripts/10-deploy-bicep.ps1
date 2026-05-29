#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Provisions the entire demo infrastructure via Bicep (Azure Resource Manager).

.DESCRIPTION
    Deploys all Azure resources defined in infra/bicep/main.bicep into the
    specified resource group. Idempotent — safe to re-run after partial failures.

    Prerequisites:
    - Az CLI installed and logged in  (az login)
    - Resource group already created  (az group create -n <rg> -l <location>)
    - infra/bicep/main.parameters.json created from main.parameters.example.json

.PARAMETER ResourceGroup
    Target resource group. Default: ai-obs-sre-demo

.PARAMETER ParametersFile
    Path to the Bicep parameters JSON file.
    Default: infra/bicep/main.parameters.example.json

.PARAMETER DeploymentName
    ARM deployment name. Default: main-<timestamp>

.EXAMPLE
    # Use defaults (RG: ai-obs-sre-demo, params: example file)
    .\10-deploy-bicep.ps1

.EXAMPLE
    # Custom RG and parameters file
    .\10-deploy-bicep.ps1 -ResourceGroup my-rg -ParametersFile .\main.parameters.json
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup  = 'ai-obs-sre-demo',
    [string] $ParametersFile = '',
    [string] $DeploymentName = "main-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$BicepDir    = Join-Path $ScriptDir '..' 'bicep'
$MainBicep   = Resolve-Path (Join-Path $BicepDir 'main.bicep')

if (-not $ParametersFile) {
    # Prefer main.parameters.json if it exists, otherwise fall back to example
    $prod = Join-Path $BicepDir 'main.parameters.json'
    $example = Join-Path $BicepDir 'main.parameters.example.json'
    $ParametersFile = if (Test-Path $prod) { $prod } else { $example }
}
$ParametersFile = Resolve-Path $ParametersFile

Write-Host ""
Write-Host "============================================================"
Write-Host "  AI Observability SRE Demo — Bicep Deployment"
Write-Host "  ResourceGroup  : $ResourceGroup"
Write-Host "  ParametersFile : $ParametersFile"
Write-Host "  DeploymentName : $DeploymentName"
Write-Host "  Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================================"

# Resolve deployer object ID
Write-Host ""
Write-Host "[1/3] Resolving deployer identity..."
$deployerOid = az ad signed-in-user show --query id -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or -not $deployerOid) {
    # Service principal or managed identity context — use service principal OID
    $deployerOid = az account show --query 'user.assignedIdentityInfo' -o tsv 2>$null
    if (-not $deployerOid) {
        Write-Warning "Could not resolve deployer object ID. Key Vault and ADX RBAC assignments may need manual attention."
        $deployerOid = '00000000-0000-0000-0000-000000000000'
    }
}
Write-Host "  Deployer OID: $deployerOid"

# Ensure RG exists
Write-Host ""
Write-Host "[2/3] Ensuring resource group '$ResourceGroup' exists..."
$rgExists = az group exists -n $ResourceGroup
if ($rgExists -eq 'false') {
    # Extract location from parameters file for RG creation
    $params = Get-Content $ParametersFile | ConvertFrom-Json
    $location = if ($params.parameters.location) { $params.parameters.location.value } else { 'australiaeast' }
    Write-Host "  Creating resource group in $location..."
    az group create -n $ResourceGroup -l $location -o none
    Write-Host "  Resource group created."
} else {
    Write-Host "  Resource group already exists."
}

# Deploy Bicep
Write-Host ""
Write-Host "[3/3] Running Bicep deployment (this takes ~25-35 minutes on first run)..."
$t = Get-Date

az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $MainBicep `
    --parameters "@$ParametersFile" `
    --parameters deployerObjectId=$deployerOid `
    --name $DeploymentName `
    --query "properties.outputs" `
    --output json

if ($LASTEXITCODE -ne 0) {
    Write-Error "Bicep deployment failed. Check the output above for details."
}

$elapsed = [int](New-TimeSpan -Start $t -End (Get-Date)).TotalSeconds
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Bicep deployment complete! ($elapsed s)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next step -> run deploy-all.ps1 with -SkipBicep to deploy"
Write-Host "application workloads (build, AKS, ADX, APIM, Grafana)."

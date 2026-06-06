#!/usr/bin/env pwsh
<#
.SYNOPSIS
    ONE-CLICK deployment of the full AI Observability SRE Demo.

.DESCRIPTION
    Runs all deployment steps in sequence:
      Step 0  — Deploy Azure infrastructure via Bicep (optional; skip if already deployed)
      Step 1  — Build & push Docker images to ACR (via ACR Tasks, no Docker needed)
      Step 2  — Deploy AKS workloads (nginx-ingress, OTel, api-service, worker-service)
      Step 3  — Bootstrap ADX schema + Event Hub data connections
      Step 4  — Apply APIM policies (inbound-correlation + diagnostics)
      Step 4.5 — Deploy UI to Azure Storage static website (pre-bakes APIM + Grafana URLs)
      Step 5  — Import Grafana datasources + dashboards
      Step 6  — Create SRE Agent (optional, requires GitHub PAT)

    FIRST-TIME SETUP:
      1. Copy infra/bicep/main.parameters.example.json -> infra/bicep/main.parameters.json
      2. Edit main.parameters.json (set prefix, location, passwords)
      3. Run: az login && az group create -n ai-obs-sre-demo -l australiaeast
      4. Run: .\deploy-all.ps1         (deploys everything including Bicep)

    SUBSEQUENT RE-DEPLOYS (infra already exists):
      .\deploy-all.ps1 -SkipBicep

    All steps are idempotent — safe to re-run after partial failures.

.PARAMETER ResourceGroup
    Azure resource group. Default: ai-obs-sre-demo

.PARAMETER Tag
    Docker image tag. Default: auto-generated UTC timestamp (yyyyMMddHHmmss).
    Supply an existing tag with -SkipBuild to skip the build step.

.PARAMETER SkipBicep
    Skip Step 0 (Bicep infrastructure). Use when infra is already deployed.

.PARAMETER SkipApimVnetInject
    Skip Step 0.5 (APIM VNet injection). Use when APIM is already VNet-injected.
    NOTE: VNet injection takes 30-45 min on first run. If skipped, APIM cannot
    reach the AKS internal LB and all orders will return 500.

.PARAMETER SkipBuild
    Skip Step 1 (build & push). Use when images are already in ACR.

.PARAMETER SkipAks
    Skip Step 2 (AKS workload deploy). Use when pods are already running.

.PARAMETER SkipAdx
    Skip Step 3 (ADX bootstrap). Use when schema/connections already exist.

.PARAMETER SkipApim
    Skip Step 4 (APIM policies). Use when policies are already applied.

.PARAMETER SkipUi
    Skip Step 4.5 (UI deploy to Azure Storage). Use when UI is already deployed.

.PARAMETER SkipGrafana
    Skip Step 5 (Grafana import). Use when dashboards are already imported.

.PARAMETER SkipSreAgent
    Skip Step 6 (SRE Agent). Default: skipped unless -RunSreAgent is specified.

.PARAMETER RunSreAgent
    Include Step 6 to create/update the SRE Agent.

.PARAMETER GithubPat
    GitHub PAT for SRE Agent step. Prompted securely if not supplied.

.PARAMETER ParametersFile
    Path to Bicep parameters JSON. Default: auto-detected from infra/bicep/.

.EXAMPLE
    # FULL FRESH DEPLOY (first time — deploys Bicep + APIM VNet inject + everything)
    # WARNING: First run takes ~60-90 min due to APIM VNet injection (30-45 min)
    .\deploy-all.ps1

.EXAMPLE
    # Infra already deployed — skip Bicep
    .\deploy-all.ps1 -SkipBicep

.EXAMPLE
    # Redeploy with an existing image tag (skip build + Bicep)
    .\deploy-all.ps1 -SkipBicep -SkipBuild -Tag 20260529093511

.EXAMPLE
    # Only update APIM + Grafana
    .\deploy-all.ps1 -SkipBicep -SkipBuild -SkipAks -SkipAdx
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup  = 'ai-obs-sre-demo',
    [string] $Tag            = (Get-Date -Format 'yyyyMMddHHmmss'),
    [switch] $SkipBicep,
    [switch] $SkipApimVnetInject,
    [switch] $SkipBuild,
    [switch] $SkipAks,
    [switch] $SkipAdx,
    [switch] $SkipApim,
    [switch] $SkipUi,
    [switch] $SkipGrafana,
    [switch] $SkipSreAgent,
    [switch] $RunSreAgent,
    [string] $GithubPat      = '',
    [string] $ParametersFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Windows encoding fix ───────────────────────────────────────────────────────
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$stepResults = [ordered]@{}
$overallStart = Get-Date

function Write-Step {
    param([string]$msg)
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action, [bool]$Skip = $false)
    if ($Skip) {
        Write-Host "  [SKIP] $Name" -ForegroundColor DarkGray
        $stepResults[$Name] = 'SKIPPED'
        return
    }
    Write-Step $Name
    $t = Get-Date
    try {
        & $Action
        $elapsed = [int](New-TimeSpan -Start $t -End (Get-Date)).TotalSeconds
        Write-Host "  [OK] $Name ($elapsed s)" -ForegroundColor Green
        $stepResults[$Name] = "OK ($elapsed s)"
    } catch {
        Write-Host "  [FAILED] $Name" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $stepResults[$Name] = "FAILED: $($_.Exception.Message)"
        throw
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  AI Observability SRE Demo — Full Deployment"
Write-Host "  ResourceGroup : $ResourceGroup"
Write-Host "  Image Tag     : $Tag"
Write-Host "  APIM VNet Inj : $(if ($SkipApimVnetInject) { 'SKIP (-SkipApimVnetInject)' } else { 'YES — Step 0.5 (30-45 min, required for APIM->AKS routing)' })"
Write-Host "  Started       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
Write-Host "============================================================"

# ── Step 0: Bicep infrastructure ──────────────────────────────────────────────
Invoke-Step -Name 'Step 0/6: Deploy Bicep infrastructure' -Skip $SkipBicep.IsPresent -Action {
    $bicepArgs = @('-ResourceGroup', $ResourceGroup)
    if ($ParametersFile) { $bicepArgs += @('-ParametersFile', $ParametersFile) }
    & "$ScriptDir\10-deploy-bicep.ps1" @bicepArgs
}

# ── Step 0.5: APIM VNet injection ────────────────────────────────────────────
# Must run AFTER Bicep (creates VNet/subnet/NSG) and BEFORE AKS workloads
# (which set APIM backend to the internal ingress IP).
# Takes 30-45 min on first run. Safe to skip with -SkipApimVnetInject if already done.
Invoke-Step -Name 'Step 0.5/6: APIM VNet injection (External mode)' -Skip $SkipApimVnetInject.IsPresent -Action {
    & "$ScriptDir\11-apim-vnet-inject.ps1" -ResourceGroup $ResourceGroup
}

# ── Step 1: Build & push images ───────────────────────────────────────────────
Invoke-Step -Name 'Step 1/6: Build & push images to ACR' -Skip $SkipBuild.IsPresent -Action {
    & "$ScriptDir\20-build-and-push.ps1" `
        -ResourceGroup $ResourceGroup `
        -Tag $Tag `
        -UseAcrTasks
}

# ── Step 2: Deploy AKS workloads ──────────────────────────────────────────────
Invoke-Step -Name 'Step 2/6: Deploy AKS workloads' -Skip $SkipAks.IsPresent -Action {
    & "$ScriptDir\30-deploy-aks.ps1" `
        -ResourceGroup $ResourceGroup `
        -Tag $Tag
}

# ── Step 3: Bootstrap ADX ─────────────────────────────────────────────────────
Invoke-Step -Name 'Step 3/6: Bootstrap ADX schema + data connections' -Skip $SkipAdx.IsPresent -Action {
    & "$ScriptDir\15-bootstrap-adx.ps1" `
        -ResourceGroup $ResourceGroup
}

# ── Step 4: Apply APIM policies ───────────────────────────────────────────────
Invoke-Step -Name 'Step 4/6: Apply APIM policies' -Skip $SkipApim.IsPresent -Action {
    & "$ScriptDir\35-apim-policies.ps1" `
        -ResourceGroup $ResourceGroup
}

# ── Step 4.5: Deploy UI to Azure Storage static website ───────────────────────
Invoke-Step -Name 'Step 4.5/6: Deploy UI to Azure Storage' -Skip $SkipUi.IsPresent -Action {
    & "$ScriptDir\45-deploy-ui.ps1" `
        -ResourceGroup $ResourceGroup
}

# ── Step 5: Import Grafana dashboards ─────────────────────────────────────────
Invoke-Step -Name 'Step 5/6: Import Grafana datasources + dashboards' -Skip $SkipGrafana.IsPresent -Action {
    & "$ScriptDir\40-import-grafana.ps1" `
        -ResourceGroup $ResourceGroup
}

# ── Step 6: SRE Agent (opt-in) ────────────────────────────────────────────────
$skipSre = (-not $RunSreAgent.IsPresent) -or $SkipSreAgent.IsPresent
Invoke-Step -Name 'Step 6/6: Create SRE Agent' -Skip $skipSre -Action {
    $sreArgs = @('-ResourceGroup', $ResourceGroup)
    if ($GithubPat) { $sreArgs += @('-GithubPat', $GithubPat) }
    & "$ScriptDir\50-create-sre-agent.ps1" @sreArgs
}

# ── Summary ───────────────────────────────────────────────────────────────────
$elapsed = [int](New-TimeSpan -Start $overallStart -End (Get-Date)).TotalSeconds

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Deployment Complete  ($elapsed s total)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

foreach ($step in $stepResults.Keys) {
    $status = $stepResults[$step]
    $color  = if ($status -like 'OK*') { 'Green' } elseif ($status -eq 'SKIPPED') { 'DarkGray' } else { 'Red' }
    Write-Host ("  {0,-45} {1}" -f $step, $status) -ForegroundColor $color
}

# Fetch quick resource links
Write-Host ""
Write-Host "--- Quick links ---" -ForegroundColor Cyan
try {
    $rg = $ResourceGroup
    $apimGw    = (az apim list -g $rg -o json | ConvertFrom-Json)[0].properties.gatewayUrl
    $grafanaUrl = (az grafana list -g $rg -o json | ConvertFrom-Json)[0].properties.endpoint
    $aksName    = (az aks list -g $rg -o json | ConvertFrom-Json)[0].name
    $uiStorAcct = (az storage account list -g $rg -o json | ConvertFrom-Json | Where-Object { $_.name -like '*ui*' } | Select-Object -First 1).name
    $uiUrl      = if ($uiStorAcct) { az storage account show -n $uiStorAcct -g $rg --query "primaryEndpoints.web" -o tsv } else { '(not deployed yet)' }
    Write-Host "  UI (Azure)   : $uiUrl" -ForegroundColor Green
    Write-Host "  APIM Gateway : $apimGw"
    Write-Host "  Grafana      : $grafanaUrl"
    Write-Host "  AKS          : $aksName (use: kubectl get pods -n app)"
    Write-Host "  Image tag    : $Tag"
} catch { }

Write-Host ""
Write-Host "To verify pods:"
Write-Host "  kubectl get pods -n app"
Write-Host "  kubectl get pods -n observability"

# ── Auto-generate .env with live APIM key ─────────────────────────────────────
# Fetches the freshly-deployed APIM subscription key and writes it to
# infra/scripts/.env (gitignored). This means you never need to manually copy
# the key — just source .env before running fault-injection or seed scripts.
Write-Host ""
Write-Host "--- Generating infra/scripts/.env with live APIM key ---" -ForegroundColor Cyan
try {
    $apimName    = (az apim list -g $ResourceGroup -o json | ConvertFrom-Json)[0].name
    $apimGwUrl   = (az apim list -g $ResourceGroup -o json | ConvertFrom-Json)[0].properties.gatewayUrl
    $cosmosName  = (az cosmosdb list -g $ResourceGroup -o json | ConvertFrom-Json)[0].name
    $apimKeyLive = az apim subscription show `
        --resource-group $ResourceGroup `
        --service-name $apimName `
        --sid voice-orders `
        --query primaryKey -o tsv 2>$null

    if ($apimKeyLive) {
        $envPath = Join-Path $ScriptDir '.env'
        $envContent = @"
# Auto-generated by deploy-all.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# DO NOT commit this file — it is gitignored.
APIM_GW_URL=$apimGwUrl
APIM_KEY=$apimKeyLive
RG=$ResourceGroup
APIM=$apimName
COSMOS_ACCOUNT=$cosmosName
"@
        Set-Content -Path $envPath -Value $envContent -Encoding UTF8
        Write-Host "  [OK] infra/scripts/.env written — APIM key populated" -ForegroundColor Green
        Write-Host "  To use in bash:       source infra/scripts/.env" -ForegroundColor DarkGray
        Write-Host "  To use in PowerShell: Get-Content infra/scripts/.env | ForEach-Object { if (`$_ -match '^\s*([^#][^=]+)=(.+)') { Set-Item `"env:`$(`$Matches[1])`" `$Matches[2] } }" -ForegroundColor DarkGray
    } else {
        Write-Host "  [WARN] Could not fetch APIM key — populate infra/scripts/.env manually." -ForegroundColor Yellow
        Write-Host "  Run: az apim subscription show --resource-group $ResourceGroup --service-name <apim-name> --sid voice-orders --query primaryKey -o tsv" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [WARN] .env generation skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

#!/usr/bin/env pwsh
<#
.SYNOPSIS
    One-click deployment of the full AI Observability SRE Demo.

.DESCRIPTION
    Runs all deployment steps in sequence:
      Step 1  — Build & push Docker images to ACR (via ACR Tasks, no Docker needed)
      Step 2  — Deploy AKS workloads (nginx-ingress, OTel, api-service, worker-service)
      Step 3  — Bootstrap ADX schema + Event Hub data connections
      Step 4  — Apply APIM policies (inbound-correlation + diagnostics)
      Step 5  — Import Grafana datasources + dashboards
      Step 6  — Create SRE Agent (optional, requires GitHub PAT)

    Infrastructure (Bicep) must already be deployed. Run 10-deploy-bicep.sh first
    if this is a fresh environment.

    All steps are idempotent — safe to re-run after partial failures.

.PARAMETER ResourceGroup
    Azure resource group. Default: ai-obs-sre-demo

.PARAMETER Tag
    Docker image tag. Default: auto-generated UTC timestamp (yyyyMMddHHmmss).
    Supply an existing tag with -SkipBuild to skip the build step.

.PARAMETER SkipBuild
    Skip Step 1 (build & push). Use when images are already in ACR.

.PARAMETER SkipAks
    Skip Step 2 (AKS workload deploy). Use when pods are already running.

.PARAMETER SkipAdx
    Skip Step 3 (ADX bootstrap). Use when schema/connections already exist.

.PARAMETER SkipApim
    Skip Step 4 (APIM policies). Use when policies are already applied.

.PARAMETER SkipGrafana
    Skip Step 5 (Grafana import). Use when dashboards are already imported.

.PARAMETER SkipSreAgent
    Skip Step 6 (SRE Agent). Default: skipped unless -RunSreAgent is specified.

.PARAMETER RunSreAgent
    Include Step 6 to create/update the SRE Agent.

.PARAMETER GithubPat
    GitHub PAT for SRE Agent step. Prompted securely if not supplied.

.EXAMPLE
    # Full fresh deploy (build everything)
    .\deploy-all.ps1

.EXAMPLE
    # Redeploy with an existing tag (skip build)
    .\deploy-all.ps1 -Tag 20260529093511 -SkipBuild

.EXAMPLE
    # Only apply APIM + Grafana (infrastructure and AKS already running)
    .\deploy-all.ps1 -SkipBuild -SkipAks -SkipAdx
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ai-obs-sre-demo',
    [string] $Tag           = (Get-Date -Format 'yyyyMMddHHmmss'),
    [switch] $SkipBuild,
    [switch] $SkipAks,
    [switch] $SkipAdx,
    [switch] $SkipApim,
    [switch] $SkipGrafana,
    [switch] $SkipSreAgent,
    [switch] $RunSreAgent,
    [string] $GithubPat     = ''
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
Write-Host "  Started       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
Write-Host "============================================================"

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
    Write-Host "  APIM Gateway : $apimGw"
    Write-Host "  Grafana      : $grafanaUrl"
    Write-Host "  AKS          : $aksName (use: kubectl get pods -n app)"
    Write-Host "  Image tag    : $Tag"
} catch { }

Write-Host ""
Write-Host "To verify pods:"
Write-Host "  kubectl get pods -n app"
Write-Host "  kubectl get pods -n observability"

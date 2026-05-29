#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pre-deployment health check: ensure ADX and AKS are Running before Bicep deploy.

.DESCRIPTION
    WHY THIS SCRIPT EXISTS
    ──────────────────────
    The lab/demo Azure subscription enforces an internal cost-saving auto-shutdown policy
    that automatically STOPS ADX clusters and AKS node pools every night to reduce costs.
    When these resources exist but are Stopped, `az deployment group create` (incremental
    mode) tries to update them in-place and fails with:
      - ADX: "Cannot fetch databases while resource is in state 'Stopped'" (HTTP 400)
      - AKS: kubectl/helm commands in 30-deploy-aks.ps1 fail with "no such host"

    This check is ONLY needed when redeploying into an existing resource group.
    On a fresh/empty resource group, ADX and AKS do not exist yet so this script
    skips them automatically and Bicep creates them from scratch without issue.

    LOGIC
    ─────
    For each of ADX and AKS:
      - If resource does NOT exist in the RG → skip (fresh deploy, Bicep will create it)
      - If resource EXISTS and is Running    → proceed
      - If resource EXISTS and is Stopped   → start it and wait until Running

.PARAMETER ResourceGroup
    Azure resource group. Default: ai-obs-sre-demo

.EXAMPLE
    # Run before every `az deployment group create`:
    .\01-precheck-start-clusters.ps1

    # Then deploy:
    $rg='ai-obs-sre-demo'; $name="main-$(Get-Date -Format yyyyMMddHHmmss)"
    az deployment group create --resource-group $rg --name $name `
      --template-file infra/bicep/main.bicep ...
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'ai-obs-sre-demo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n=== Pre-Deploy Cluster Health Check ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroup"
Write-Host ""
Write-Host "NOTE: This check exists because the lab subscription has an internal cost-saving" -ForegroundColor DarkYellow
Write-Host "      auto-shutdown policy that stops ADX and AKS every night. It only applies" -ForegroundColor DarkYellow
Write-Host "      when these resources already exist (redeployment). On a clean resource" -ForegroundColor DarkYellow
Write-Host "      group this script exits immediately with nothing to do." -ForegroundColor DarkYellow
Write-Host ""

$allReady = $true

# ─────────────────────────────────────────────────────────────────────────────
# ADX CLUSTER CHECK
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[ADX] Checking for existing ADX cluster..." -NoNewline

$adxClusters = az kusto cluster list -g $ResourceGroup -o json 2>&1 | ConvertFrom-Json
$adx = $adxClusters | Select-Object -First 1

if (-not $adx) {
    Write-Host " not found." -ForegroundColor DarkGray
    Write-Host "      → Fresh deploy: Bicep will create ADX from scratch. No action needed." -ForegroundColor DarkGray
} else {
    Write-Host " found: $($adx.name)" -ForegroundColor White
    Write-Host "       State: $($adx.state)" -NoNewline

    if ($adx.state -eq 'Running') {
        Write-Host " ✓" -ForegroundColor Green
    } else {
        Write-Host " (stopped by cost-saving policy — starting...)" -ForegroundColor Yellow
        az kusto cluster start --name $adx.name --resource-group $ResourceGroup --no-wait 2>&1 | Out-Null

        Write-Host "       Waiting for ADX to reach Running state (typically 5-10 min)..."
        $timeout = (Get-Date).AddMinutes(15)
        do {
            Start-Sleep -Seconds 30
            $state = az kusto cluster show --name $adx.name -g $ResourceGroup --query "state" -o tsv 2>&1
            Write-Host "       $(Get-Date -Format HH:mm:ss)  ADX state: $state"
            if ((Get-Date) -gt $timeout) {
                Write-Error "ADX did not reach Running within 15 minutes. Check Azure portal."
            }
        } while ($state -ne 'Running')

        Write-Host "       ADX is Running ✓" -ForegroundColor Green
    }
}

Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# AKS CLUSTER CHECK
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[AKS] Checking for existing AKS cluster..." -NoNewline

$aksClusters = az aks list -g $ResourceGroup -o json 2>&1 | ConvertFrom-Json
$aks = $aksClusters | Select-Object -First 1

if (-not $aks) {
    Write-Host " not found." -ForegroundColor DarkGray
    Write-Host "      → Fresh deploy: Bicep will create AKS from scratch. No action needed." -ForegroundColor DarkGray
} else {
    Write-Host " found: $($aks.name)" -ForegroundColor White
    $powerState = $aks.powerState.code
    $provState  = $aks.provisioningState
    Write-Host "       Power: $powerState  |  Provisioning: $provState" -NoNewline

    if ($powerState -eq 'Running' -and $provState -eq 'Succeeded') {
        Write-Host " ✓" -ForegroundColor Green
    } elseif ($provState -ne 'Succeeded') {
        # An in-progress operation (e.g. previous deploy still running) — must wait
        Write-Host " (provisioning in progress — waiting for terminal state...)" -ForegroundColor Yellow
        $timeout = (Get-Date).AddMinutes(20)
        do {
            Start-Sleep -Seconds 30
            $aksInfo    = az aks show -g $ResourceGroup -n $aks.name -o json 2>&1 | ConvertFrom-Json
            $powerState = $aksInfo.powerState.code
            $provState  = $aksInfo.provisioningState
            Write-Host "       $(Get-Date -Format HH:mm:ss)  Power: $powerState  Prov: $provState"
            if ((Get-Date) -gt $timeout) {
                Write-Error "AKS did not reach Succeeded within 20 minutes. Check Azure portal."
            }
        } while ($provState -ne 'Succeeded')
        Write-Host "       AKS provisioning complete ✓" -ForegroundColor Green
    } else {
        # Power = Stopped, provisioningState = Succeeded → start it
        Write-Host " (stopped by cost-saving policy — starting...)" -ForegroundColor Yellow
        az aks start --name $aks.name --resource-group $ResourceGroup --no-wait 2>&1 | Out-Null

        Write-Host "       Waiting for AKS to reach Running state (typically 3-5 min)..."
        $timeout = (Get-Date).AddMinutes(15)
        do {
            Start-Sleep -Seconds 30
            $aksInfo    = az aks show -g $ResourceGroup -n $aks.name -o json 2>&1 | ConvertFrom-Json
            $powerState = $aksInfo.powerState.code
            $provState  = $aksInfo.provisioningState
            Write-Host "       $(Get-Date -Format HH:mm:ss)  Power: $powerState  Prov: $provState"
            if ((Get-Date) -gt $timeout) {
                Write-Error "AKS did not reach Running within 15 minutes. Check Azure portal."
            }
        } while (-not ($powerState -eq 'Running' -and $provState -eq 'Succeeded'))

        Write-Host "       AKS is Running ✓" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " All existing clusters are Running." -ForegroundColor Green
Write-Host " Safe to run az deployment group create." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

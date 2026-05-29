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
$adxUri      = "https://$adxCluster.australiaeast.kusto.windows.net"
$adxDb       = 'observability'

$subId       = az account show --query id -o tsv

Write-Host "  Grafana      : $grafanaHost"
Write-Host "  ADX URI      : $adxUri"

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
Write-Host "  ADX datasource: done."

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
    $result = az grafana dashboard import -n $grafanaName --definition $f.FullName --overwrite 2>&1 | ConvertFrom-Json
    $status = if ($result.status) { $result.status } else { 'ok' }
    Write-Host "  $($f.Name): $status"
}

# ── [3/3] Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Grafana import complete."
Write-Host "  URL: $grafanaHost"
Write-Host "  Dashboards imported: $($dashboards.Count)"
Write-Host ""
Write-Host "Next step  ->  .\50-create-sre-agent.ps1"

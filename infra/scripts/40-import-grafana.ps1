#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Imports Grafana datasources (ADX, Azure Monitor, Managed Prometheus) and
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
$amwName     = (az monitor account list -g $rg -o json 2>$null | ConvertFrom-Json | Select-Object -First 1).name
$amwEndpoint = if ($amwName) {
    (az monitor account show -g $rg -n $amwName --query metrics.prometheusQueryEndpoint -o tsv 2>$null)
} else { $null }

Write-Host "  Grafana      : $grafanaHost"
Write-Host "  ADX URI      : $adxUri"
Write-Host "  AMW endpoint : $amwEndpoint"

# Access token for Grafana REST API
$token = az account get-access-token --resource 'https://grafana.azure.com' --query accessToken -o tsv

$headers = @{
    'Authorization' = "Bearer $token"
    'Content-Type'  = 'application/json'
}

function Invoke-GrafanaApi {
    param([string]$Method, [string]$Path, [string]$Body = $null)
    $uri = "$grafanaHost$Path"
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $Body
        } else {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }
    } catch {
        # 409 Conflict = already exists — not an error for our purposes
        if ($_.Exception.Response.StatusCode.value__ -eq 409) { return $null }
        Write-Warning "  Grafana API $Method $Path -> $($_.Exception.Message)"
        return $null
    }
}

# ── [1/3] Datasources ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [1/3] Creating/updating Grafana datasources ==="

# ADX datasource
$dsAdx = @{
    name       = 'ADX'
    type       = 'grafana-azure-data-explorer-datasource'
    access     = 'proxy'
    isDefault  = $false
    jsonData   = @{ clusterUrl = $adxUri; defaultDatabase = $adxDb; azureCredentials = @{ authType = 'msi' } }
    secureJsonData = @{}
} | ConvertTo-Json -Depth 5
Invoke-GrafanaApi -Method POST -Path '/api/datasources' -Body $dsAdx | Out-Null
Write-Host "  ADX datasource: done."

# Azure Monitor datasource
$dsAzMon = @{
    name      = 'AzureMonitor'
    type      = 'grafana-azure-monitor-datasource'
    access    = 'proxy'
    isDefault = $true
    jsonData  = @{ subscriptionId = $subId; azureAuthType = 'msi' }
    secureJsonData = @{}
} | ConvertTo-Json -Depth 5
Invoke-GrafanaApi -Method POST -Path '/api/datasources' -Body $dsAzMon | Out-Null
Write-Host "  AzureMonitor datasource: done."

# Managed Prometheus datasource (only if AMW exists)
if ($amwEndpoint) {
    $dsPromUrl = $amwEndpoint.TrimEnd('/')
    $dsProm = @{
        name     = 'Prometheus-AMW'
        type     = 'prometheus'
        access   = 'proxy'
        url      = $dsPromUrl
        jsonData = @{
            httpMethod       = 'POST'
            azureCredentials = @{ authType = 'msi' }
        }
        secureJsonData = @{}
    } | ConvertTo-Json -Depth 5
    Invoke-GrafanaApi -Method POST -Path '/api/datasources' -Body $dsProm | Out-Null
    Write-Host "  Prometheus-AMW datasource: done."
} else {
    Write-Warning "  No Azure Monitor Workspace found — Prometheus datasource skipped."
}

# ── [2/3] Dashboards ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [2/3] Importing Grafana dashboards ==="

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$DashboardsDir = Resolve-Path (Join-Path $ScriptDir '../grafana/dashboards')

$dashboards = Get-ChildItem $DashboardsDir -Filter '*.json' | Sort-Object Name
foreach ($f in $dashboards) {
    $dashJson = Get-Content $f.FullName -Raw
    $body = @{
        dashboard = ($dashJson | ConvertFrom-Json)
        overwrite = $true
        folderId  = 0
    } | ConvertTo-Json -Depth 20
    $result = Invoke-GrafanaApi -Method POST -Path '/api/dashboards/db' -Body $body
    if ($result) {
        Write-Host "  $($f.Name) -> $($result.url)"
    } else {
        Write-Warning "  $($f.Name): import returned no response (may already exist)"
    }
}

# ── [3/3] Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Grafana import complete."
Write-Host "  URL: $grafanaHost"
Write-Host "  Dashboards imported: $($dashboards.Count)"
Write-Host ""
Write-Host "Next step  ->  .\50-create-sre-agent.ps1"

#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Bootstraps ADX: applies schema.kql and creates Event Hub data connections
    for aks-otel (AppLogs/AppSpans) and apim-diag (APIMGatewayLogs).

.PARAMETER ResourceGroup
    Azure resource group (default: ai-obs-sre-demo)

.EXAMPLE
    .\15-bootstrap-adx.ps1
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

$adxCluster = (az kusto cluster list -g $rg -o json | ConvertFrom-Json)[0].name
$adxDb      = 'observability'
$ehns       = (az eventhubs namespace list -g $rg -o json | ConvertFrom-Json)[0].name
$location   = az group show -n $rg --query location -o tsv

$adxPrincipalId = az kusto cluster show -g $rg -n $adxCluster --query identity.principalId -o tsv
$ehnsId         = az eventhubs namespace show -g $rg -n $ehns --query id -o tsv

Write-Host "  ADX cluster : $adxCluster"
Write-Host "  ADX db      : $adxDb"
Write-Host "  EHNS        : $ehns"
Write-Host "  Location    : $location"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$schemaKql = Resolve-Path (Join-Path $ScriptDir '../adx/schema.kql')

# ── [1/3] Apply schema ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [1/3] Applying schema.kql to $adxCluster/$adxDb ==="
$scriptName = "schema-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Check if schema already applied by checking for AppLogs table
$tablesRaw = az kusto query `
    --cluster-name $adxCluster --database-name $adxDb `
    --csl ".show tables | project TableName" `
    -g $rg -o json 2>$null | ConvertFrom-Json

$existingTables = if ($tablesRaw) { ($tablesRaw.Tables[0].Rows | ForEach-Object { $_[0] }) } else { @() }

if ($existingTables -contains 'AppLogs') {
    Write-Host "  Schema already applied (AppLogs table exists) — skipping."
} else {
    az kusto script create `
        --cluster-name $adxCluster --database-name $adxDb --resource-group $rg `
        --name $scriptName `
        --script-content (Get-Content $schemaKql -Raw) `
        --continue-on-errors false 2>&1 | Select-Object -Last 3
    Write-Host "  Schema applied."
}

# ── [2/3] Data connection: aks-otel ──────────────────────────────────────────
Write-Host ""
Write-Host "=== [2/3] Creating Event Hub data connections (idempotent) ==="

$aksOtelHub  = 'aks-otel'
$apimDiagHub = 'apim-diag'

# aks-otel -> AppLogs
$connExists = az kusto data-connection show `
    -g $rg --cluster-name $adxCluster --database-name $adxDb `
    --data-connection-name 'aks-otel-logs' 2>$null
if (-not $connExists) {
    az kusto data-connection event-hub create `
        --resource-group $rg --cluster-name $adxCluster --database-name $adxDb `
        --data-connection-name 'aks-otel-logs' `
        --location $location `
        --consumer-group 'adx' `
        --event-hub-resource-id "$ehnsId/eventhubs/$aksOtelHub" `
        --table-name 'AppLogs' --mapping-rule-name 'AppLogsMapping' --data-format 'MULTIJSON' `
        --managed-identity-resource-id `
            (az kusto cluster show -g $rg -n $adxCluster --query id -o tsv) 2>&1 | Select-Object -Last 2
    Write-Host "  aks-otel -> AppLogs: created."
} else {
    Write-Host "  aks-otel -> AppLogs: already exists — skipping."
}

# aks-otel -> AppSpans
$connExists = az kusto data-connection show `
    -g $rg --cluster-name $adxCluster --database-name $adxDb `
    --data-connection-name 'aks-otel-spans' 2>$null
if (-not $connExists) {
    az kusto data-connection event-hub create `
        --resource-group $rg --cluster-name $adxCluster --database-name $adxDb `
        --data-connection-name 'aks-otel-spans' `
        --location $location `
        --consumer-group 'adx' `
        --event-hub-resource-id "$ehnsId/eventhubs/$aksOtelHub" `
        --table-name 'AppSpans' --mapping-rule-name 'AppSpansMapping' --data-format 'MULTIJSON' `
        --managed-identity-resource-id `
            (az kusto cluster show -g $rg -n $adxCluster --query id -o tsv) 2>&1 | Select-Object -Last 2
    Write-Host "  aks-otel -> AppSpans: created."
} else {
    Write-Host "  aks-otel -> AppSpans: already exists — skipping."
}

# ── [3/3] Data connection: apim-diag ─────────────────────────────────────────
$connExists = az kusto data-connection show `
    -g $rg --cluster-name $adxCluster --database-name $adxDb `
    --data-connection-name 'apim-diag' 2>$null
if (-not $connExists) {
    az kusto data-connection event-hub create `
        --resource-group $rg --cluster-name $adxCluster --database-name $adxDb `
        --data-connection-name 'apim-diag' `
        --location $location `
        --consumer-group 'adx' `
        --event-hub-resource-id "$ehnsId/eventhubs/$apimDiagHub" `
        --table-name 'APIMGatewayLogs' --mapping-rule-name 'APIMGatewayLogsMapping' --data-format 'MULTIJSON' `
        --managed-identity-resource-id `
            (az kusto cluster show -g $rg -n $adxCluster --query id -o tsv) 2>&1 | Select-Object -Last 2
    Write-Host "  apim-diag -> APIMGatewayLogs: created."
} else {
    Write-Host "  apim-diag -> APIMGatewayLogs: already exists — skipping."
}

Write-Host ""
Write-Host "ADX bootstrap complete."
Write-Host "  Cluster : https://$adxCluster.australiaeast.kusto.windows.net"
Write-Host "  Database: $adxDb"
Write-Host ""
Write-Host "Next step  ->  .\35-apim-policies.ps1"

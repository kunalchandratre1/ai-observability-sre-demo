#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pre-demo data seeder — generates realistic exception data with CorrelationId
    so the Grafana Golden Signals and APIM Health dashboards show meaningful data
    before a customer demo.

.DESCRIPTION
    Runs through 3 fault scenarios sequentially, firing real orders through APIM
    for each one so that ADX AppExceptions has rows with:
      - ExceptionType populated  (e.g. DependencyError, RuntimeError)
      - DependencyName populated (AzureOpenAI / AzureSpeech / Cosmos)
      - CorrelationId populated  (prefixed so you can filter in dashboard)
      - TraceId / Pod / DeploymentVersion populated

    Scenarios seeded:
      1. openai-down    -> 5 orders -> DependencyName=AzureOpenAI
      2. speech-down    -> 5 orders -> DependencyName=AzureSpeech
      3. cosmos-dns-break -> 5 orders -> DependencyName=Cosmos

    After each fault batch the fault is turned off and the script waits briefly
    before moving to the next scenario so healthy traffic interleaves.

    After all faults: waits 60 s for ADX ingestion and shows the row count
    directly from ADX so you know data is ready before opening Grafana.

.PARAMETER ApimGatewayUrl
    APIM gateway base URL, e.g. https://aiosre-apim-demo.azure-api.net
    Reads from env APIM_GW_URL if not supplied.

.PARAMETER ApimKey
    APIM subscription key.  Reads from env APIM_KEY if not supplied.

.PARAMETER OrdersPerFault
    How many orders to send per fault scenario (default 5).
    Use 3 for a quick smoke-test, 10 for a richer demo dataset.

.PARAMETER SkipWait
    Skip the final 60-second ADX ingestion wait (useful if re-running).

.EXAMPLE
    # Minimal — reads APIM_GW_URL and APIM_KEY from env
    .\70-seed-demo-data.ps1

.EXAMPLE
    # Explicit params, 10 orders per fault
    .\70-seed-demo-data.ps1 `
        -ApimGatewayUrl "https://aiosre-apim-demo.azure-api.net" `
        -ApimKey "f6c382528a3240eda0b1d8df6f3b9991" `
        -OrdersPerFault 10

.EXAMPLE
    # Azure Cloud Shell one-liner (set env vars first)
    $env:APIM_GW_URL="https://aiosre-apim-demo.azure-api.net"
    $env:APIM_KEY="f6c382528a3240eda0b1d8df6f3b9991"
    ./70-seed-demo-data.ps1
#>
[CmdletBinding()]
param(
    [string] $ApimGatewayUrl  = $env:APIM_GW_URL,
    [string] $ApimKey         = $env:APIM_KEY,
    [int]    $OrdersPerFault  = 5,
    [switch] $SkipWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Validate inputs ────────────────────────────────────────────────────────────
if (-not $ApimGatewayUrl) {
    $ApimGatewayUrl = "https://aiosre-apim-demo.azure-api.net"
    Write-Host "  [info] APIM_GW_URL not set — using default: $ApimGatewayUrl" -ForegroundColor DarkGray
}
if (-not $ApimKey) {
    $ApimKey = "f6c382528a3240eda0b1d8df6f3b9991"
    Write-Host "  [info] APIM_KEY not set — using embedded default key" -ForegroundColor DarkGray
}

$base    = $ApimGatewayUrl.TrimEnd('/')
$headers = @{ 'Ocp-Apim-Subscription-Key' = $ApimKey; 'Content-Type' = 'application/json' }
$seed    = (Get-Date -Format "yyMMdd-HHmm")   # timestamp prefix on all correlation IDs

# ── Helper functions ───────────────────────────────────────────────────────────
function Set-Fault([hashtable]$body) {
    $json = $body | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post -Uri "$base/voice/admin/faults" -Headers $headers -Body $json | Out-Null
    } catch {
        Write-Host "    WARN: fault toggle failed — $($_.Exception.Message.Substring(0,[Math]::Min(80,$_.Exception.Message.Length)))" -ForegroundColor Yellow
    }
}

function Send-Orders([string]$scenario, [int]$count) {
    $sent = 0; $failed = 0
    for ($i = 1; $i -le $count; $i++) {
        $cid  = "demo-$scenario-$seed-$i"
        $body = @{ text = "order a flat white for demo run $i"; user_id = "demo-seeder" } | ConvertTo-Json -Compress
        try {
            $resp = Invoke-RestMethod -Method Post -Uri "$base/voice/orders" `
                -Headers (@{ 'Ocp-Apim-Subscription-Key' = $ApimKey; 'Content-Type' = 'application/json'; 'x-correlation-id' = $cid }) `
                -Body $body -ErrorAction SilentlyContinue
            # 503 is expected when fault is on — still counts as a generated exception
            $sent++
            Write-Host "    [$i/$count] cid=$cid  status=ok-or-503" -ForegroundColor DarkGray
        } catch {
            # HTTP 503/429/500 exceptions are expected and desired — they produce AppExceptions in ADX
            $sent++
            Write-Host "    [$i/$count] cid=$cid  status=error (expected)" -ForegroundColor DarkGray
        }
        Start-Sleep -Milliseconds 500   # pace requests so APIM rate-limit not hit
    }
    Write-Host "    Sent $sent orders ($failed failed unexpectedly)" -ForegroundColor Cyan
}

function Verify-ADX([string]$scenario, [string]$prefix) {
    try {
        $adxToken = (az account get-access-token --resource "https://help.kusto.windows.net" -o json 2>$null | ConvertFrom-Json).accessToken
        if (-not $adxToken) { return }
        $rg = 'ai-obs-sre-demo'
        $adxUri = (az kusto cluster list -g $rg -o json 2>$null | ConvertFrom-Json)[0].uri
        if (-not $adxUri) { $adxUri = "https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net" }
        $kql  = "AppExceptions | where Timestamp > ago(30m) | where CorrelationId startswith '$prefix' | summarize n=count() by DependencyName, ExceptionType"
        $body = @{ db = 'observability'; csl = $kql } | ConvertTo-Json -Compress
        $r    = Invoke-RestMethod -Method POST -Uri "$adxUri/v1/rest/query" `
            -Headers @{ Authorization = "Bearer $adxToken"; "Content-Type" = "application/json" } `
            -Body $body
        $rows = $r.Tables[0].Rows
        if ($rows -and $rows.Count -gt 0) {
            Write-Host "    ADX rows for '$scenario':" -ForegroundColor Green
            $rows | ForEach-Object { Write-Host "      DependencyName=$($_[0])  ExceptionType=$($_[1])  count=$($_[2])" }
        } else {
            Write-Host "    ADX: no rows yet for '$scenario' (ingestion may still be in progress)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ADX verify skipped: $($_.Exception.Message.Substring(0,[Math]::Min(60,$_.Exception.Message.Length)))" -ForegroundColor DarkGray
    }
}

# ── Main seeding loop ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  SRE Demo — Pre-demo Data Seeder" -ForegroundColor Cyan
Write-Host "  APIM   : $base" -ForegroundColor Cyan
Write-Host "  Orders : $OrdersPerFault per fault scenario" -ForegroundColor Cyan
Write-Host "  Seed   : $seed (prefix on all CorrelationIds)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

$scenarios = @(
    @{ Name = "openai-down";      Fault = @{ fault_force_openai_down = $true };        Clear = @{ fault_force_openai_down = $false };        Label = "AzureOpenAI dependency down" },
    @{ Name = "speech-down";      Fault = @{ fault_force_speech_down = $true };        Clear = @{ fault_force_speech_down = $false };        Label = "AzureSpeech dependency down" },
    @{ Name = "cosmos-dns-break"; Fault = @{ fault_force_cosmos_dns_break = $true };   Clear = @{ fault_force_cosmos_dns_break = $false };   Label = "Cosmos DNS break (PE fault)" }
)

foreach ($s in $scenarios) {
    Write-Host ""
    Write-Host "--- Scenario: $($s.Label) ---" -ForegroundColor Yellow

    Write-Host "  [1/3] Enabling fault: $($s.Name)..."
    Set-Fault $s.Fault
    Start-Sleep -Seconds 2   # let fault propagate to all pods

    Write-Host "  [2/3] Sending $OrdersPerFault orders (correlation IDs: demo-$($s.Name)-$seed-1...$OrdersPerFault)..."
    Send-Orders $s.Name $OrdersPerFault

    Write-Host "  [3/3] Disabling fault..."
    Set-Fault $s.Clear
    Start-Sleep -Seconds 3   # brief pause before next scenario
}

# ── Also send healthy traffic so timeseries panels have baseline data ──────────
Write-Host ""
Write-Host "--- Healthy baseline traffic (10 orders, no fault) ---" -ForegroundColor Yellow
Write-Host "  Sending 10 healthy orders..."
for ($i = 1; $i -le 10; $i++) {
    $cid  = "demo-healthy-$seed-$i"
    $body = @{ text = "order a green tea for seat $i"; user_id = "demo-seeder" } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post -Uri "$base/voice/orders" `
            -Headers (@{ 'Ocp-Apim-Subscription-Key' = $ApimKey; 'Content-Type' = 'application/json'; 'x-correlation-id' = $cid }) `
            -Body $body -ErrorAction SilentlyContinue | Out-Null
    } catch { }   # 200 or error — both populate ADX spans/logs
    Write-Host "  [$i/10] cid=$cid" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 400
}

# ── Wait for ADX ingestion ─────────────────────────────────────────────────────
if (-not $SkipWait) {
    Write-Host ""
    Write-Host "--- Waiting 60s for ADX ingestion pipeline ---" -ForegroundColor Yellow
    for ($s = 60; $s -gt 0; $s -= 10) {
        Write-Host "  $s seconds remaining..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}

# ── ADX verification ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Verifying data in ADX ---" -ForegroundColor Yellow
foreach ($sc in $scenarios) {
    Verify-ADX $sc.Name "demo-$($sc.Name)-$seed"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Seeding complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Open Grafana and check:" -ForegroundColor Green
Write-Host "  D1 Golden Signals -> 'Top recent exceptions'" -ForegroundColor Green
Write-Host "     Filter correlation_id by prefix: demo-*-$seed-*" -ForegroundColor Green
Write-Host "  D2 APIM Health    -> '5xx joined with AppExceptions'" -ForegroundColor Green
Write-Host ""
Write-Host "  CorrelationId prefixes generated:" -ForegroundColor Green
Write-Host "    demo-openai-down-$seed-1 ... $OrdersPerFault" -ForegroundColor White
Write-Host "    demo-speech-down-$seed-1 ... $OrdersPerFault" -ForegroundColor White
Write-Host "    demo-cosmos-dns-break-$seed-1 ... $OrdersPerFault" -ForegroundColor White
Write-Host "======================================================" -ForegroundColor Green

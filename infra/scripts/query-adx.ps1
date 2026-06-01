#!/usr/bin/env pwsh
# query-adx.ps1  — quick validation of ADX tables
param([string]$KustoUri = "https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net", [string]$DB = "observability")

$token = az account get-access-token --resource "https://help.kusto.windows.net" --query accessToken -o tsv
$h = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

function q([string]$csl, [string]$label) {
    Write-Host "`n[$label]" -ForegroundColor Cyan
    $body = @{ db = $DB; csl = $csl } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod "$KustoUri/v1/rest/query" -Method POST -Headers $h -Body $body
        $rows = $r.Tables[0].Rows
        Write-Host "  rows: $($rows.Count)"
        $rows | Select-Object -First 3 | ForEach-Object { "  $_" }
    } catch { Write-Host "  ERR: $($_.Exception.Message.Substring(0,[Math]::Min(200,$_.Exception.Message.Length)))" -ForegroundColor Red }
}

q "RawAksOtel | count" "RawAksOtel count"
q "RawAksOtel | take 2 | project _type=tostring(records._type), svc=tostring(records.resource['service.name'])" "RawAksOtel sample"
q "AppLogs | count" "AppLogs count"
q "AppSpans | count" "AppSpans count"
q "APIMGatewayLogs | count" "APIMGatewayLogs count"

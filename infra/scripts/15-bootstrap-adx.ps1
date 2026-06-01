#!/usr/bin/env pwsh
# ============================================================================
# 15-bootstrap-adx.ps1
# Bootstrap ADX schema, ingestion mappings, update policies, and Event Hub
# data connections for the ai-observability-sre-demo stack.
#
# Fixes vs original:
#   - Uses `az rest` ARM PUT instead of deprecated `az kusto data-connection`
#   - managedIdentityResourceId = ADX cluster resource ID (not principalId)
#   - Single data connection aks-otel→RawAksOtel (update policies fan-out to
#     AppLogs/AppSpans), eliminating shared consumer-group conflict
#   - Applies schema via Kusto REST API /v1/rest/mgmt with field `csl`
#   - Grants ADX MI "Azure Event Hubs Data Receiver" on EH namespace
# ============================================================================
param(
    [string]$ResourceGroup = "ai-obs-sre-demo",
    [string]$AdxCluster    = "",              # auto-detected from RG if empty
    [string]$AdxDb         = "observability",
    [string]$EhNs          = "",              # auto-detected from RG if empty
    [string]$AksOtelHub    = "aks-otel",
    [string]$ApimDiagHub   = "apim-diag"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RG = $ResourceGroup

# ── Auto-detect resource names from resource group ───────────────────────────
Write-Host "`n=== ADX Bootstrap ===" -ForegroundColor Cyan
Write-Host "  ResourceGroup: $RG"

$Sub = az account show --query id -o tsv

if (-not $AdxCluster) {
    $AdxCluster = (az kusto cluster list -g $RG -o json | ConvertFrom-Json)[0].name
    Write-Host "  Auto-detected ADX cluster: $AdxCluster"
}
if (-not $EhNs) {
    $EhNs = (az eventhubs namespace list -g $RG -o json | ConvertFrom-Json)[0].name
    Write-Host "  Auto-detected EH namespace: $EhNs"
}

$EhNsId   = az eventhubs namespace show -g $RG -n $EhNs --query id -o tsv
$AdxResId = "/subscriptions/$Sub/resourceGroups/$RG/providers/Microsoft.Kusto/clusters/$AdxCluster"
$AdxMiOid = az kusto cluster show -g $RG -n $AdxCluster --query identity.principalId -o tsv 2>$null
# Use cluster's actual data ingestion URI (works across any region)
$KustoUri = az kusto cluster show -g $RG -n $AdxCluster --query uri -o tsv
$Loc      = az kusto cluster show -g $RG -n $AdxCluster --query location -o tsv

Write-Host "  ADX Cluster  : $AdxCluster / $AdxDb  ($KustoUri)"
Write-Host "  EH Namespace : $EhNs"
Write-Host "  ADX MI OID   : $AdxMiOid"

# ── Step 1: Consumer groups ──────────────────────────────────────────────────
Write-Host "`n[1/4] Creating Event Hub consumer groups..." -ForegroundColor Yellow
foreach ($hub in @($AksOtelHub, $ApimDiagHub)) {
    az eventhubs eventhub consumer-group create -g $RG --namespace-name $EhNs `
        --eventhub-name $hub --name adx 2>&1 | Out-Null
    Write-Host "  $hub/adx : OK (or already existed)"
}

# ── Step 2: RBAC ─────────────────────────────────────────────────────────────
Write-Host "`n[2/4] Granting ADX MI 'Azure Event Hubs Data Receiver' on EH namespace..." -ForegroundColor Yellow
# Role GUID: Azure Event Hubs Data Receiver = a638d3c7-ab3a-418d-83e6-5f17a39d4fde
az role assignment create `
    --assignee $AdxMiOid `
    --role "a638d3c7-ab3a-418d-83e6-5f17a39d4fde" `
    --scope $EhNsId 2>&1 | Out-Null
Write-Host "  Role assignment: OK (or already existed)"

# ── Step 3: Apply schema via Kusto REST API ──────────────────────────────────
Write-Host "`n[3/4] Applying ADX schema (tables, mappings, update policies, retention)..." -ForegroundColor Yellow
$KustoToken   = az account get-access-token --resource "https://help.kusto.windows.net" --query accessToken -o tsv
$KustoHeaders = @{ Authorization = "Bearer $KustoToken"; "Content-Type" = "application/json" }

function Invoke-Kql([string]$csl, [string]$label) {
    Write-Host "  [$label]..." -NoNewline
    $body = @{ db = $AdxDb; csl = $csl } | ConvertTo-Json -Depth 10 -Compress
    try {
        $null = Invoke-RestMethod "$KustoUri/v1/rest/mgmt" -Method POST -Headers $KustoHeaders -Body $body
        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " WARN: $($_.Exception.Message.Substring(0,[Math]::Min(120,$_.Exception.Message.Length)))" -ForegroundColor Yellow
    }
}

# Tables
Invoke-Kql ".create-merge table RawAksOtel (records:dynamic)" "RawAksOtel table"
Invoke-Kql ".create-merge table RawApimDiag (records:dynamic)" "RawApimDiag table"
Invoke-Kql ".create-merge table AppLogs (Timestamp:datetime, SeverityText:string, Body:dynamic, Resource:dynamic, Attributes:dynamic, TraceId:string, SpanId:string, CorrelationId:string, RequestId:string, UserId:string, OrderId:string, ServiceName:string, DeploymentVersion:string, Pod:string, Namespace:string, Node:string)" "AppLogs table"
Invoke-Kql ".create-merge table AppSpans (Timestamp:datetime, EndTimestamp:datetime, DurationMs:real, TraceId:string, SpanId:string, ParentSpanId:string, Name:string, Kind:string, StatusCode:string, StatusMessage:string, Attributes:dynamic, Resource:dynamic, Events:dynamic, Links:dynamic, CorrelationId:string, RequestId:string, UserId:string, OrderId:string, DependencyName:string, DependencyEndpoint:string, DependencyStatusCode:int, DependencyLatencyMs:real, ErrorType:string, ErrorMessage:string, ServiceName:string, DeploymentVersion:string, Pod:string, Namespace:string)" "AppSpans table"
Invoke-Kql ".create-merge table AppExceptions (Timestamp:datetime, TraceId:string, SpanId:string, CorrelationId:string, RequestId:string, UserId:string, OrderId:string, ExceptionType:string, ExceptionMessage:string, StackTrace:string, DependencyName:string, ServiceName:string, DeploymentVersion:string, Pod:string, Namespace:string)" "AppExceptions table"
Invoke-Kql ".create-merge table APIMGatewayLogs (Timestamp:datetime, ApiId:string, ApiName:string, OperationName:string, Method:string, Url:string, BackendUrl:string, RequestId:string, CorrelationId:string, Traceparent:string, Tracestate:string, SubscriptionId:string, ClientIp:string, Status:int, BackendStatus:int, TotalTimeMs:real, BackendTimeMs:real, ErrorReason:string, ErrorMessage:string)" "APIMGatewayLogs table"

# Ingestion mappings
$rawMapping  = '[{"column":"records","path":"$","datatype":"dynamic"}]'
$apimMapping = '[{"column":"Timestamp","path":"$.ts"},{"column":"ApiId","path":"$.apiId"},{"column":"ApiName","path":"$.apiName"},{"column":"OperationName","path":"$.operationName"},{"column":"Method","path":"$.method"},{"column":"Url","path":"$.url"},{"column":"BackendUrl","path":"$.backendUrl"},{"column":"RequestId","path":"$.requestId"},{"column":"CorrelationId","path":"$.correlationId"},{"column":"Traceparent","path":"$.traceparent"},{"column":"Tracestate","path":"$.tracestate"},{"column":"SubscriptionId","path":"$.subscriptionId"},{"column":"ClientIp","path":"$.clientIp"},{"column":"Status","path":"$.status"},{"column":"BackendStatus","path":"$.backendStatus"},{"column":"TotalTimeMs","path":"$.totalTimeMs"},{"column":"BackendTimeMs","path":"$.backendTimeMs"},{"column":"ErrorReason","path":"$.errorReason"},{"column":"ErrorMessage","path":"$.errorMessage"}]'
Invoke-Kql ".create-or-alter table RawAksOtel ingestion json mapping 'RawAksOtelMapping' '$rawMapping'" "RawAksOtelMapping"
Invoke-Kql ".create-or-alter table APIMGatewayLogs ingestion json mapping 'APIMGatewayLogsMapping' '$apimMapping'" "APIMGatewayLogsMapping"

# Update-policy support functions
Invoke-Kql @"
.create-or-alter function AppExceptionsExtract() {
    AppLogs
    | where SeverityText in ("ERROR","FATAL")
    | where isnotempty(tostring(Attributes["exception.type"])) or isnotempty(tostring(Attributes["error.type"]))
    | extend ExceptionType    = coalesce(tostring(Attributes["exception.type"]), tostring(Attributes["error.type"]))
    | extend ExceptionMessage = coalesce(tostring(Attributes["exception.message"]), tostring(Attributes["error.message"]))
    | extend StackTrace       = tostring(Attributes["exception.stacktrace"])
    | extend DependencyName   = tostring(Attributes["dependency_name"])
    | project Timestamp, TraceId, SpanId, CorrelationId, RequestId, UserId, OrderId,
              ExceptionType, ExceptionMessage, StackTrace, DependencyName,
              ServiceName, DeploymentVersion, Pod, Namespace
}
"@ "AppExceptionsExtract fn"

Invoke-Kql @"
.create-or-alter function RawAksOtelToAppLogs() {
    RawAksOtel
    | where records._type == "log"
    | project
        Timestamp         = unixtime_seconds_todatetime(tolong(tostring(records["timeUnixNano"])) / 1000000000),
        SeverityText      = tostring(records["severityText"]),
        Body              = records["body"],
        Resource          = records["resource"],
        Attributes        = records["attributes"],
        TraceId           = tostring(records["traceId"]),
        SpanId            = tostring(records["spanId"]),
        CorrelationId     = tostring(records["attributes"]["correlation_id"]),
        RequestId         = tostring(records["attributes"]["request_id"]),
        UserId            = tostring(records["attributes"]["user_id"]),
        OrderId           = tostring(records["attributes"]["order_id"]),
        ServiceName       = tostring(records["resource"]["service.name"]),
        DeploymentVersion = tostring(records["resource"]["service.version"]),
        Pod               = tostring(records["resource"]["k8s.pod.name"]),
        Namespace         = tostring(records["resource"]["k8s.namespace.name"]),
        Node              = tostring(records["resource"]["k8s.node.name"])
}
"@ "RawAksOtelToAppLogs fn"

Invoke-Kql @"
.create-or-alter function RawAksOtelToAppSpans() {
    RawAksOtel
    | where records._type == "span"
    | extend startNs = tolong(tostring(records["startTimeUnixNano"]))
    | extend endNs   = tolong(tostring(records["endTimeUnixNano"]))
    | project
        Timestamp            = unixtime_seconds_todatetime(startNs / 1000000000),
        EndTimestamp         = unixtime_seconds_todatetime(endNs / 1000000000),
        DurationMs           = todouble(endNs - startNs) / 1000000.0,
        TraceId              = tostring(records["traceId"]),
        SpanId               = tostring(records["spanId"]),
        ParentSpanId         = tostring(records["parentSpanId"]),
        Name                 = tostring(records["name"]),
        Kind                 = tostring(records["kind"]),
        StatusCode           = tostring(records["status"]["code"]),
        StatusMessage        = tostring(records["status"]["message"]),
        Attributes           = records["attributes"],
        Resource             = records["resource"],
        Events               = records["events"],
        Links                = records["links"],
        CorrelationId        = tostring(records["attributes"]["correlation_id"]),
        RequestId            = tostring(records["attributes"]["request_id"]),
        UserId               = tostring(records["attributes"]["user_id"]),
        OrderId              = tostring(records["attributes"]["order_id"]),
        DependencyName       = tostring(records["attributes"]["dependency_name"]),
        DependencyEndpoint   = tostring(records["attributes"]["dependency.endpoint"]),
        DependencyStatusCode = toint(records["attributes"]["dependency.status_code"]),
        DependencyLatencyMs  = todouble(records["attributes"]["dependency.latency_ms"]),
        ErrorType            = tostring(records["attributes"]["error.type"]),
        ErrorMessage         = tostring(records["attributes"]["error.message"]),
        ServiceName          = tostring(records["resource"]["service.name"]),
        DeploymentVersion    = tostring(records["resource"]["service.version"]),
        Pod                  = tostring(records["resource"]["k8s.pod.name"]),
        Namespace            = tostring(records["resource"]["k8s.namespace.name"])
}
"@ "RawAksOtelToAppSpans fn"

# Update policies (single-quoted strings in KQL — use '' for embedded single quotes)
Invoke-Kql '.alter table AppExceptions policy update @''[{"Source":"AppLogs","Query":"AppExceptionsExtract()","IsEnabled":true,"IsTransactional":false}]''' "AppExceptions<-AppLogs"
Invoke-Kql '.alter table AppLogs       policy update @''[{"Source":"RawAksOtel","Query":"RawAksOtelToAppLogs()","IsEnabled":true,"IsTransactional":false}]''' "AppLogs<-RawAksOtel"
Invoke-Kql '.alter table AppSpans      policy update @''[{"Source":"RawAksOtel","Query":"RawAksOtelToAppSpans()","IsEnabled":true,"IsTransactional":false}]''' "AppSpans<-RawAksOtel"

# Retention (30 days on the four query-facing tables)
$ret30d = '{"SoftDeletePeriod":"30.00:00:00","Recoverability":"Enabled"}'
foreach ($tbl in @("AppLogs","AppSpans","AppExceptions","APIMGatewayLogs")) {
    Invoke-Kql ".alter table $tbl policy retention '$ret30d'" "$tbl retention"
}

# Ingestion batching (1 min for demo responsiveness — default is 5 min)
$batchPolicy = '{"MaximumBatchingTimeSpan":"00:01:00","MaximumNumberOfItems":500,"MaximumRawDataSizeMB":1024}'
Invoke-Kql ".alter table RawAksOtel   policy ingestionbatching '$batchPolicy'" "RawAksOtel batching 1min"
Invoke-Kql ".alter table RawApimDiag  policy ingestionbatching '$batchPolicy'" "RawApimDiag batching 1min"
Invoke-Kql ".alter table APIMGatewayLogs policy ingestionbatching '$batchPolicy'" "APIMGatewayLogs batching 1min"

# ── Step 4: Data connections (ARM REST PUT — idempotent) ─────────────────────
Write-Host "`n[4/4] Creating ADX Event Hub data connections..." -ForegroundColor Yellow
$BaseUrl = "https://management.azure.com/subscriptions/$Sub/resourceGroups/$RG/providers/Microsoft.Kusto/clusters/$AdxCluster/databases/$AdxDb/dataConnections"
$ApiVer  = "2023-08-15"

function New-DataConnection([string]$name, [string]$hub, [string]$table, [string]$mapping) {
    Write-Host "  [$name] hub=$hub → table=$table ..." -NoNewline
    $body = @{
        kind     = "EventHub"
        location = $Loc
        properties = @{
            eventHubResourceId        = "$EhNsId/eventhubs/$hub"
            consumerGroup             = "adx"
            tableName                 = $table
            mappingRuleName           = $mapping
            dataFormat                = "JSON"
            managedIdentityResourceId = $AdxResId   # cluster resource ID, NOT principalId
            compression               = "None"
            databaseRouting           = "Single"
        }
    } | ConvertTo-Json -Depth 5

    # Write to temp file to avoid PowerShell quoting issues with az rest --body inline JSON
    $tmpFile = [System.IO.Path]::GetTempFileName()
    $body | Out-File $tmpFile -Encoding utf8 -NoNewline
    try {
        $r = az rest --method PUT --url "$BaseUrl/${name}?api-version=$ApiVer" --body "@$tmpFile" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $state = ($r | ConvertFrom-Json).properties.provisioningState
            Write-Host " $state" -ForegroundColor Green
        } else {
            Write-Host " FAILED: $($r -join '')" -ForegroundColor Red
        }
    } finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
}

# aks-otel → RawAksOtel  (update policies fan-out to AppLogs and AppSpans)
New-DataConnection "aks-otel-raw"   $AksOtelHub  "RawAksOtel"      "RawAksOtelMapping"
# apim-diag → APIMGatewayLogs  (flat APIM diagnostic JSON lands directly)
New-DataConnection "apim-diag-logs" $ApimDiagHub "APIMGatewayLogs" "APIMGatewayLogsMapping"

Write-Host "`n=== Bootstrap complete ===" -ForegroundColor Green
Write-Host "Data connections provision asynchronously — verify in ~2 min:"
Write-Host "  az rest --method GET --url 'https://management.azure.com$AdxResId/databases/$AdxDb/dataConnections?api-version=$ApiVer'"
Write-Host "`nNext step → .\35-apim-policies.ps1"

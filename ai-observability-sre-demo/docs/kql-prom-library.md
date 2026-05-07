# KQL / PromQL / Az Monitor library

## ADX (KQL)
```kql
// Recent backend exceptions, last 15m
AppExceptions
| where Timestamp > ago(15m)
| summarize n=count() by ServiceName, ExceptionType, DependencyName
| order by n desc

// One transaction end-to-end (paste your trace_id)
let tid = "<paste>";
union AppSpans, AppLogs, AppExceptions
| where TraceId == tid
| order by Timestamp asc

// APIM 5xx joined to backend errors via correlation_id
APIMGatewayLogs
| where Status >= 500 and Timestamp > ago(30m)
| join kind=leftouter (AppExceptions | project CorrelationId, ExceptionType, ExceptionMessage, Pod) on CorrelationId
| project Timestamp, OperationName, Status, BackendStatus, CorrelationId, ExceptionType, ExceptionMessage, Pod

// Detect bad deploy
AppExceptions | summarize errs=count() by DeploymentVersion
| join kind=fullouter (AppSpans | summarize reqs=count() by DeploymentVersion) on DeploymentVersion
| extend rate = todouble(coalesce(errs,0))/todouble(coalesce(reqs,1))
| order by rate desc
```

## PromQL (Managed Prometheus, AMW)
```promql
# Per-pod CPU
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="app"}[2m]))

# HPA replicas vs desired
kube_horizontalpodautoscaler_status_current_replicas{namespace="app"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="app"}

# Pod restart rate
sum by (pod) (rate(kube_pod_container_status_restarts_total{namespace="app"}[5m]))
```

## Azure Monitor metric expressions (APIM)
- `Requests` — Total
- `FailedRequests` — Total
- `Duration` — P50/P95/P99
- `Capacity` — Average

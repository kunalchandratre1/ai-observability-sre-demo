# Future Roadmap

Improvements tracked here are **not yet implemented** in the current demo deployment. Each item describes the problem it solves, the implementation approach, and its priority.

---

## R1 — Application exception alerting → trigger SRE Agent incident response plan

**Priority:** High  
**Status:** Not implemented  
**Solves:** Application exceptions are currently only stored in ADX (`AppExceptions` table). ADX cannot natively trigger Azure Monitor alert rules, so a critical application exception (e.g. `ClientAuthenticationError`, `CosmosException`, unhandled 500) that occurs when all Azure infrastructure is healthy will **not** trigger the `SREFaultInvestigation` incident response plan automatically.

### Problem in detail

```
Current flow (gap highlighted):
  api-service / worker-service
    → OTel SDK → OTel Collector → Event Hub → ADX ✅
                                                ↑
                                   ADX cannot fire Azure Monitor alerts ❌
                                   → SREFaultInvestigation never triggers on app exceptions
```

The 5 existing alert rules (`apim-backend-errors`, `aks-pod-crashloop`, etc.) all fire on infrastructure signals (APIM 5xx rate, pod crashloop, DLQ depth). A pure application-layer exception — e.g. a bug in `api-service` that raises a 500 while all pods are Running and APIM shows no metric anomaly — produces no alert and no automated incident response.

### Solution: OTel Collector selective fan-out to Log Analytics

Add a **second, lightweight OTel pipeline** in the Collector that fans **ERROR-severity signals only** to Log Analytics (App Insights). The full-fidelity telemetry continues to flow to ADX unchanged.

```
AFTER:
  api-service / worker-service
    → OTel SDK
      → OTel Collector
          ├── Pipeline 1 (unchanged): ALL signals → Event Hub → ADX
          └── Pipeline 2 (new): ERROR+ only → Azure Monitor (App Insights) → LAW
                                                      ↓
                                           Log search alert rule (LAW)
                                                      ↓
                                           SREFaultInvestigation fires (Sev 1)
                                                      ↓
                                           SREObservabilityExpert queries ADX
                                           for full root cause (stack trace,
                                           correlation_id, affected service)
```

### Implementation steps

#### Step 1 — App Insights resource (Bicep: `infra/bicep/modules/monitoring.bicep`)

Add an Application Insights resource linked to the existing Log Analytics workspace:

```bicep
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-appinsights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id  // links to aiosre-la-demo
  }
}
output appInsightsConnectionString string = appInsights.properties.ConnectionString
```

This routes App Insights data into `aiosre-la-demo` under the `AppExceptions` and `AppTraces` tables — natively queryable by log search alert rules.

#### Step 2 — OTel Collector config (`api/otel/collector-config.yaml`)

Add a `filter` processor and `azuremonitor` exporter, then wire a second pipeline:

```yaml
processors:
  # existing processors unchanged
  memory_limiter: ...
  batch: ...

  # NEW: drop everything below ERROR severity
  filter/exceptions_only:
    error_mode: ignore
    logs:
      log_record:
        - 'severity_number < SEVERITY_NUMBER_ERROR'
    traces:
      span:
        - 'status.code != STATUS_CODE_ERROR'

exporters:
  # existing exporter unchanged
  azureeventhub: ...

  # NEW: sends ERROR+ signals to App Insights → LAW
  azuremonitor:
    connection_string: "${APP_INSIGHTS_CONNECTION_STRING}"

service:
  pipelines:
    # existing pipeline unchanged
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [azureeventhub]

    # NEW: error-only pipeline → LAW
    logs/exceptions:
      receivers: [otlp]
      processors: [memory_limiter, filter/exceptions_only, batch]
      exporters: [azuremonitor]

    traces/exceptions:
      receivers: [otlp]
      processors: [memory_limiter, filter/exceptions_only, batch]
      exporters: [azuremonitor]
```

#### Step 3 — Pass connection string to Collector (AKS: `api/k8s/app.yaml`)

Mount the App Insights connection string as an env var from a Kubernetes secret:

```yaml
# In otel-collector Deployment env:
- name: APP_INSIGHTS_CONNECTION_STRING
  valueFrom:
    secretKeyRef:
      name: appinsights-secret
      key: connection_string
```

Create the secret during deploy (add to `infra/scripts/30-deploy-aks.sh`):

```bash
kubectl create secret generic appinsights-secret \
  --from-literal=connection_string="$APP_INSIGHTS_CONNECTION_STRING" \
  --namespace app --dry-run=client -o yaml | kubectl apply -f -
```

#### Step 4 — Log search alert rule (Bicep: `infra/bicep/modules/monitoring.bicep`)

```bicep
resource appExceptionAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'app-exception-spike'
  location: location
  properties: {
    severity: 1  // Sev 1 — triggers SREFaultInvestigation
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [logAnalyticsWorkspace.id]
    criteria: {
      allOf: [
        {
          query: '''
            AppExceptions
            | where TimeGenerated > ago(5m)
            | where SeverityLevel >= 3
            | summarize exception_count = count() by ExceptionType
            | where exception_count > 0
          '''
          threshold: 0
          operator: 'GreaterThan'
          timeAggregation: 'Count'
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroupId]  // existing action group
    }
  }
}
```

#### Step 5 — Add to Section 7 of verification checklist

Once implemented, add `app-exception-spike` to the alert rules table in `docs/verification-checklist.md` Section 7:

| Alert name | Type | Severity | Expected state |
|---|---|---|---|
| `app-exception-spike` | Log search | Sev 1 | Enabled, not fired |

### Expected end-to-end flow after implementation

1. `api-service` raises an unhandled exception (e.g. Cosmos `ServiceUnavailable`)
2. OTel SDK emits error-severity log + error span
3. OTel Collector **pipeline 1**: routes to Event Hub → ADX `AppExceptions` (unchanged, full fidelity)
4. OTel Collector **pipeline 2**: `filter/exceptions_only` passes it → `azuremonitor` exporter → App Insights → LAW `AppExceptions` table (exception summary only, no stack trace duplication overhead)
5. Log search alert `app-exception-spike` fires → Sev 1 Azure Monitor alert
6. `SREFaultInvestigation` incident response plan activates → `SREObservabilityExpert` runs
7. Agent calls `QueryRecentAppErrors` → queries ADX `AppExceptions` (full stack trace, `CorrelationId`, `ServiceName`, `DeploymentVersion`)
8. Agent returns root cause analysis: which service, which exception type, which transaction, which deploy version

### Cost impact

- App Insights resource: ~$0/month at demo volumes (free tier covers 5 GB/month ingestion)
- LAW ingestion: exceptions are a tiny fraction of total telemetry — estimated < 1% of current ADX volume
- OTel Collector CPU: filter processor is negligible; second pipeline adds ~5% CPU overhead

---

## R2 — Grafana alert → SRE Agent integration

**Priority:** Medium  
**Status:** Not implemented  
**Solves:** Grafana dashboards (D1–D5) have visual anomaly detection but cannot directly trigger the SRE Agent incident response plan. A Grafana alert firing on `AppSpans` latency spike or `AppExceptions` count would need to route through Azure Monitor Alerts to reach the incident plan.

**Approach:** Grafana → Azure Monitor Action Group webhook → Azure Monitor Alert (forwarded) → SRE Agent incident plan. Requires a small Azure Function or Logic App to bridge the Grafana webhook payload to an Azure Monitor alert format.

---

## R3 — Multi-region fault injection

**Priority:** Low  
**Status:** Not implemented  
**Solves:** All fault scenarios currently run in a single region (Australia East). Adding a secondary region (e.g. Southeast Asia) would demonstrate cross-region latency degradation, Traffic Manager failover, and Cosmos geo-replication lag as observable signals in Grafana and ADX.

---

## R4 — Automated chaos schedule (Azure Chaos Studio)

**Priority:** Low  
**Status:** Not implemented  
**Solves:** Fault injection is currently manual (`infra/scripts/60-fault-toggle.sh`). Azure Chaos Studio experiments can run on a schedule or be triggered by CI/CD pipeline, enabling continuous resilience testing. Experiments would target the same fault scenarios (DNS break, rate limit, CPU saturation) with automated verification of SRE Agent response quality.

---

## R5 — Scenario 9: Firewall rule misconfiguration (infrastructure-layer fault)

**Priority:** Medium  
**Status:** Not implemented  
**Solves:** All 8 existing fault scenarios are triggered via code toggles, APIM policy changes, or DNS rewrites — none simulate a pure **infrastructure configuration change** as the root cause. This scenario adds a fault where a firewall rule disables public access to Service Bus, causing real SDK-level connection failures that the SRE Agent must trace back to an Azure Activity Log event rather than application code.

### Problem it demonstrates

The SRE Agent currently has no `QueryAzureActivityLog` tool. Without it, it cannot answer: *"Nothing was deployed, but orders are failing — did someone change an Azure resource configuration?"* This is a common real-world scenario (a network engineer inadvertently tightens a firewall rule, or a policy enforcer auto-remediates a compliance violation).

### Fault mechanism

```powershell
# Inject — blocks all public access to Service Bus
az servicebus namespace update -g ai-obs-sre-demo --name <sb-name> --public-network-access Disabled

# Remediate — restore
az servicebus namespace update -g ai-obs-sre-demo --name <sb-name> --public-network-access Enabled
```

- No code change, no image rebuild — pure Azure resource config toggle
- `azure-servicebus` SDK throws real `ServiceBusAuthorizationError` / `ConnectionRefusedError`
- OTel span records the error → flows to ADX as a genuine dependency failure

### SRE Agent reasoning chain

```
User: "Orders are queuing up and not being processed. Nothing was deployed. What changed?"
  ↓
QueryDependencyErrors(15m, "ServiceBus") → 100% errors, ServiceBusAuthorizationError
  ↓
DeploymentCorrelation(1h) → no new deployment_version → not a code regression
  ↓
QueryAzureActivityLog(1h) → finds Microsoft.ServiceBus/namespaces/write
  setting publicNetworkAccess=Disabled at T-12min, Caller=<identity>
  ↓
Root cause: Firewall misconfiguration — Service Bus public network access disabled
```

### Files to build

| File | Change |
|---|---|
| `infra/scripts/60-fault-toggle.ps1` / `.sh` | Add `servicebus-firewall-block` case |
| `infra/sre-agent/kusto-tools/QueryAzureActivityLog.kql` | New KQL tool |
| SRE agent system prompt | Register `QueryAzureActivityLog` as callable tool |
| `docs/runbooks/09-servicebus-firewall.md` | New runbook |

### Pre-requisite

Verify Azure Activity Logs are exported to the Log Analytics workspace. If not, add a subscription-level diagnostic setting in `infra/bicep/modules/monitoring.bicep` to route Activity Logs to the existing LAW.

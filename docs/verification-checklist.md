# Pre-Fault-Injection Verification Checklist

Run through every section below **before** starting fault injection. Every checkbox must be green.
All items reference the actual deployed environment: subscription `ba43c91f-2d76-4000-a7ad-24750cab54c3`, RG `ai-obs-sre-demo`, region `Australia East`.

---

## Reference values

| Resource | Value |
|---|---|
| **UI (App Service)** | **`https://aiosre-ui-demo.azurewebsites.net`** |
| APIM gateway URL | `https://aiosre-apim-demo.azure-api.net` |
| APIM subscription key | `f6c382528a3240eda0b1d8df6f3b9991` |
| Grafana URL | `https://aiosre-grafana-demo-hebrbpdbdtfrhmdg.eau.grafana.azure.com` |
| ADX cluster URI | `https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net` |
| ADX database | `observability` |
| Log Analytics workspace | `aiosre-la-demo` (RG `ai-obs-sre-demo`) |
| SRE Agent URL | `https://sre.azure.com/agents/subscriptions/ba43c91f-2d76-4000-a7ad-24750cab54c3/resourceGroups/ai-obs-sre-demo/providers/Microsoft.App/agents/aiosre-sre-agent-demo` |

---

## Section 1 — UI: Submit a transaction and verify IDs

**Open the UI** using one of the options below:

| Option | How to open |
|---|---|
| **Azure App Service (deployed)** ✅ | **`https://aiosre-ui-demo.azurewebsites.net`** — APIM URL + Grafana URL pre-configured by `45-deploy-ui.ps1` |
| **Local (Python)** | `cd ui/public && python -m http.server 8080` → open `http://localhost:8080` |
| **Local (VS Code Live Server)** | Right-click `ui/public/index.html` → *Open with Live Server* |

> **Tip:** The deployed App Service has APIM gateway URL and Grafana URL pre-baked into `app.js` by the deploy script. APIM subscription key is stored in browser `localStorage` after first entry.

### 1.1 — Configure the UI
- [ ] APIM gateway URL filled in: `https://aiosre-apim-demo.azure-api.net`
- [ ] Subscription key filled in (see reference values above)
- [ ] Grafana base URL filled in

### 1.2 — Submit one order
- [ ] Click **Submit (POST /voice/orders)**
- [ ] Response shows HTTP 200 (green)
- [ ] `correlation_id` field populated (UUID format e.g. `550e8400-e29b-...`)
- [ ] `request_id` field populated
- [ ] `trace_id` field populated (W3C hex format)
- [ ] `order_id` field populated
- [ ] **All 4 dependency cards green:**
  - [ ] `AzureOpenAI` — status: ok
  - [ ] `AzureSpeech` — status: ok
  - [ ] `ThirdPartyAPI` — status: ok
  - [ ] `Cosmos` — status: ok

> **What each field means:**
> - `correlation_id` — single UUID that links **every log, span, and APIM gateway entry** for this transaction across all systems. Primary key for ADX/Grafana filters. During fault injection, this is how you trace which layer broke.
> - `request_id` — unique per HTTP request; used to deduplicate logs and correlate APIM's gateway log with the backend log.
> - `trace_id` — W3C distributed trace ID propagated as `traceparent` header through APIM → api-service → worker-service. Links spans in Grafana D1 waterfall.
> - `order_id` — business handle (e.g. `order-5eea44d2a6`); written to Cosmos DB by worker-service; visible in Grafana D4 Cosmos panel.

> **What each dependency simulates:**
> - `AzureOpenAI` — calls Azure OpenAI `gpt-4o` to extract loan intent from the submitted text (~1–3s). **Mandatory** — order fails with 503 if broken. *Fault scenario: OpenAI rate limit / outage.*
> - `AzureSpeech` — calls Azure Speech TTS to synthesize *"Your order has been received"* (~400–800ms). **Mandatory** — order fails with 503 if broken. *Fault scenario: Speech service down.*
> - `ThirdPartyAPI` — calls an external public API over the internet (~800–1500ms). Simulates an external SaaS dependency. **Non-fatal** — order succeeds even if broken. *Fault scenario: third-party timeout / unreachable.*
> - `Cosmos` — written **asynchronously** by worker-service after Service Bus dequeue; not in the synchronous response path. Simulates a private-endpoint database write. *Fault scenarios: Cosmos PE DNS break, RU throttle (429).*

> **Action:** Copy the `correlation_id` and `trace_id` from this transaction. Paste them into every query below to trace the same transaction end-to-end.

### 1.3 — Submit a burst
- [ ] Click **Burst x10** — 10 requests fire
- [ ] All return 200 (no red dep cards)

---

## Section 2 — APIM: Gateway logs and correlation propagation

**Portal:** `https://portal.azure.com` → search `aiosre-apim-demo`

### 2.1 — Azure Monitor metrics
- [ ] APIM → **Metrics** → `Requests` split by `Backend Response Code` → 200s visible, no 5xx
- [ ] APIM → **Metrics** → `Duration` → baseline latency visible (no spikes)

### 2.2 — APIM gateway logs in Log Analytics
**APIM → Logs** (or LAW `aiosre-la-demo`):
```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(30m)
| project TimeGenerated, OperationId, ResponseCode, BackendResponseCode, DurationMs, ClientIp
| order by TimeGenerated desc
| take 20
```
- [ ] Rows appear (not empty)
- [ ] `ResponseCode` = 200 for healthy requests
- [ ] `BackendResponseCode` = 200 (APIM and backend in sync — no mismatch)

### 2.3 — Trace your correlation_id through APIM (ADX)
**ADX Web UI** → database `observability`:
```kql
APIMGatewayLogs
| where CorrelationId == "<paste your correlation_id>"
| project Timestamp, OperationName, Status, DurationMs, BackendUrl, CorrelationId
```
- [ ] Exactly 1 row returned matching your correlation_id
- [ ] `BackendUrl` shows the AKS internal ingress private URL

---

## Section 3 — ADX: All 4 telemetry tables have live data

**Open:** [ADX Web UI](https://dataexplorer.azure.com) → cluster `aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net` → database `observability`

> **What is ADX and what does it store?**
>
> Azure Data Explorer (`observability` database) is the **primary analytical store** for all application telemetry. It holds 4 tables:
>
> | Table | What each row represents | Who writes it |
> |---|---|---|
> | `AppLogs` | One structured log line (INFO/ERROR/WARN) — includes `Body`, `SeverityText`, `ServiceName`, `Pod`, `CorrelationId` | api-service, worker-service |
> | `AppSpans` | One **distributed trace span** — a timed unit of work (e.g. "POST /api/orders", "dep.AzureOpenAI"). Includes `DependencyName`, `DependencyLatencyMs`, `DependencyStatusCode`, `ErrorType` | api-service, worker-service |
> | `AppExceptions` | One caught exception — `ExceptionType`, `ExceptionMessage`, `StackTrace`, `DependencyName`, `CorrelationId` | api-service, worker-service |
> | `APIMGatewayLogs` | One APIM gateway request — `Status`, `BackendStatus`, `TotalTimeMs`, `CorrelationId` | APIM diagnostic setting |
>
> **How data flows into ADX:**
> ```
> api-service / worker-service
>   → OTel SDK (OTLP) → OTel Collector (AKS) → Event Hub: aks-otel
>     → ADX data connection → RawAksOtel
>       → update policy fans out to AppLogs / AppSpans / AppExceptions
>
> APIM Gateway
>   → Diagnostic Setting (Event Hub logger) → Event Hub: apim-diag
>     → ADX data connection → APIMGatewayLogs
> ```
>
> **How the SRE Agent uses ADX:**
> - `QueryRecentAppErrors` → queries `AppExceptions` — finds what is failing and on which service/pod
> - `QueryDependencyErrors` → queries `AppSpans + AppExceptions` — per-dependency error rate, latency p95, exception breakdown
> - `APIMvsBackendCorrelation` → joins `APIMGatewayLogs ⟕ AppExceptions` on `CorrelationId` — proves fault is at APIM vs backend
> - `TraceDrilldown` → queries `AppSpans` by `CorrelationId` — reconstructs full span waterfall for a single transaction
> - `DeploymentCorrelation` → groups `AppExceptions` by `DeploymentVersion` — pinpoints which deploy introduced the regression

### 3.1 — Row counts
```kql
AppLogs | count
AppSpans | count
AppExceptions | count
APIMGatewayLogs | count
```
- [ ] `AppLogs` — count > 0
- [ ] `AppSpans` — count > 0
- [ ] `AppExceptions` — count > 0
- [ ] `APIMGatewayLogs` — count > 0

### 3.2 — Recency check (data is current, not stale)
**ADX Web UI** → cluster `aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net` → database `observability`:
```kql
union withsource=Type AppLogs, AppSpans, AppExceptions, APIMGatewayLogs
| summarize latest = max(Timestamp) by Type
```
> `withsource=Type` tells `union` to add a column named `Type` containing the source table name for each row. Without it, `union` merges rows with no table label and `summarize by Type` fails with "Failed to resolve scalar expression named 'Type'". All 4 types should show `latest` within the last 30 minutes — if one is stale, the corresponding ingestion pipeline (Event Hub → ADX data connection) has a gap.
- [ ] All 4 types show `latest` within the last 30 minutes

### 3.3 — End-to-end trace for your transaction
```kql
union AppLogs, AppSpans, AppExceptions
| where CorrelationId == "<paste your correlation_id>"
| project Timestamp, Type, ServiceName, Name, DependencyName, Level, ExceptionType, CorrelationId
| order by Timestamp asc
```
- [ ] Multiple rows returned (spans + logs from both `api-service` and `worker-service`)
- [ ] Spans cover: order receipt, OpenAI call, Speech call, ThirdParty call, SB enqueue, Cosmos write
- [ ] `CorrelationId` is consistent across ALL rows — no breaks in propagation

### 3.4 — Dependency latency data
```kql
AppSpans
| where Timestamp > ago(1h)
| summarize count(), avg(DependencyLatencyMs) by DependencyName
```
- [ ] Rows present for `AzureOpenAI`, `AzureSpeech`, `ThirdPartyAPI`, `Cosmos`
- [ ] `avg_DependencyLatencyMs` is non-zero and reasonable

### 3.5 — Deployment version visible
```kql
AppLogs
| summarize count() by DeploymentVersion, ServiceName
```
- [ ] At least one version for both `api-service` and `worker-service`

---

## Section 4 — Grafana: All 5 dashboards show live data

**Open:** `https://aiosre-grafana-demo-hebrbpdbdtfrhmdg.eau.grafana.azure.com`

Set time range to **Last 1 hour**. Refresh all dashboards.

### D1 — End-to-End Golden Signals
- [ ] **Panel 1: Latency p95 per dependency** — lines visible for all 4 dependencies
- [ ] **Panel 2: Errors per minute** — low/zero (no spikes at baseline)
- [ ] **Panel 3: Traffic (req/min)** — traffic spike visible from Burst x10
- [ ] **Panel 4: AKS pod CPU (Managed Prometheus)** — per-pod CPU lines visible
- [ ] **Panel 5: Top exceptions table** — rows present
- [ ] **Panel 6: Deployment versions stat** — current version displayed
- [ ] **Filter test:** Paste your `correlation_id` into the variable box → Panel 5 filters to your single transaction

### D2 — APIM Health
- [ ] **Panel 1: APIM 4xx/5xx (Azure Monitor)** — 200s visible, zero 5xx
- [ ] **Panel 2: APIM Latency p95 (Azure Monitor)** — latency line visible
- [ ] **Panel 3: Status by operation (ADX)** — operation names from your requests visible
- [ ] **Panel 4: APIM diagnostics table** — rows with your correlation_id visible

### D3 — AI Dependencies Health
- [ ] **Panel 1: OpenAI latency p50/p95** — lines with realistic values (100–3000ms)
- [ ] **Panel 2: OpenAI errors/min** — zero baseline
- [ ] **Panel 3: Speech latency p95** — lines visible
- [ ] **Panel 4: Speech errors/min** — zero baseline
- [ ] **Panel 5: AI failures table** — empty or near-empty at baseline

### D4 — Cosmos Private Endpoint Health
- [ ] **Panel 1: Cosmos write errors** — zero baseline
- [ ] **Panel 2: Cosmos call latency (worker)** — lines visible
- [ ] **Panel 3: DNS/PE resolution failures table** — empty (no DNS failures at baseline)
- [ ] **Panel 4: Successful Cosmos writes stat** — non-zero number

### D5 — Third-party Dependency Health
- [ ] **Panel 1: 3rd-party latency p95** — lines visible
- [ ] **Panel 2: 3rd-party errors/min** — zero baseline
- [ ] **Panel 3: 3rd-party failures table** — empty at baseline

---

## Section 5 — Log Analytics: AKS infrastructure + PaaS diagnostic logs

**Portal:** LAW `aiosre-la-demo` → **Logs**

### 5.1 — AKS container logs (application stdout)
```kql
ContainerLog
| where TimeGenerated > ago(30m)
| where LogEntry has_any ("api-service","worker-service","INFO","ERROR")
| order by TimeGenerated desc
| take 20
```
- [ ] Rows present — application container logs flowing

### 5.2 — AKS pod health
```kql
KubePodInventory
| where TimeGenerated > ago(10m)
| where Namespace == "app"
| project TimeGenerated, Name, PodStatus, ContainerStatus, Node
| order by TimeGenerated desc
```
- [ ] `api-service-*` pods visible — `PodStatus` = `Running`
- [ ] `worker-service-*` pods visible — `PodStatus` = `Running`
- [ ] No `CrashLoopBackOff` or `OOMKilled` status

### 5.3 — KubeEvents (zero error events at baseline)
```kql
KubeEvents
| where TimeGenerated > ago(30m)
| where Reason in ("BackOff","CrashLoopBackOff","OOMKilling","Failed")
| order by TimeGenerated desc
```
- [ ] **Zero rows returned** at baseline

### 5.4 — AKS node perf metrics
```kql
Perf
| where TimeGenerated > ago(30m)
| where ObjectName == "K8SNode"
| summarize avg(CounterValue) by CounterName, Computer
```
- [ ] Rows visible for CPU and memory counters per node

### 5.5 — Cosmos diagnostic logs
```kql
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.DOCUMENTDB"
| summarize count() by OperationName, ResultType
| order by count_ desc
```
- [ ] Rows present — Cosmos operations visible
- [ ] `ResultType` = `Success` dominant — no failures at baseline

### 5.6 — Service Bus diagnostic logs
```kql
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.SERVICEBUS"
| summarize count() by OperationName, ResultType
```
- [ ] Rows present — Service Bus operations visible

### 5.7 — On-prem VM syslog
```kql
Syslog
| where TimeGenerated > ago(1h)
| order by TimeGenerated desc
| take 10
```
- [ ] Rows present — VM syslog flowing from on-prem (peered VNet via VPN Gateway)
- [ ] If empty: check that the on-prem VM's Log Analytics agent is connected (VM → Extensions → MMA/OMS agent installed and heartbeat present)

### 5.8 — Redis diagnostic logs
```kql
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.CACHE"
| summarize count() by OperationName, ResultType
```
- [ ] Rows present

### 5.9 — Key Vault audit logs
```kql
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| project TimeGenerated, OperationName, ResultType, CallerIpAddress
| order by TimeGenerated desc
| take 10
```
- [ ] Rows present — Key Vault access audit visible

---

## Section 6 — SRE Agent: Verify connectivity and skill

**Open:** `https://sre.azure.com` → `aiosre-sre-agent-demo`

### 6.1 — All sources green (home page banner)
- [ ] Banner shows **"All sources configured"**
- [ ] Code: 1 repository ✅
- [ ] Logs: 2 log providers ✅
- [ ] Incidents: Azure Monitor ✅
- [ ] Azure resources: 1 Azure resource ✅
- [ ] Knowledge files: 9 files ✅

### 6.2 — Smoke test: basic ADX query
In the chat box:
```
Show me the most recent application errors in the last 30 minutes
```
- [ ] Agent calls `QueryRecentAppErrors` (visible in reasoning steps)
- [ ] Returns exception types and counts from ADX
- [ ] `correlation_id` values in response are real (UUID format — not invented)

### 6.3 — Custom agent smoke test
```
/agent SREObservabilityExpert Are there any dependency failures in the last hour?
```
- [ ] `SREObservabilityExpert` activates (shown in response header)
- [ ] Agent calls `QueryDependencyErrors` via ADX Kusto skill
- [ ] Returns per-dependency breakdown across OpenAI, Speech, Cosmos, ThirdParty

### 6.4 — Incident response plan is active
- [ ] **Builder → Incident response plans** → `SREFaultInvestigation` shows as **Active**
- [ ] Severity filter: Sev 1 and Sev 2 selected
- [ ] Response subagent: `SREObservabilityExpert`

---

## Section 7 — Azure Monitor Alert Rules

**Portal:** Azure Monitor → Alerts → Alert rules → filter by RG `ai-obs-sre-demo`

| Alert name | Type | Severity | Expected state |
|---|---|---|---|
| `apim-backend-errors` | Metric | Sev 2 | Enabled, not fired |
| `aks-pod-crashloop` | Log search | Sev 2 | Enabled, not fired |
| `aks-container-errors` | Log search | Sev 2 | Enabled, not fired |
| `cosmos-connection-failures` | Log search | Sev 1 | Enabled, not fired |
| `servicebus-dlq-spike` | Metric | Sev 2 | Enabled, not fired |

- [ ] All 5 alert rules exist
- [ ] All 5 are **Enabled**
- [ ] All 5 show **Condition met: 0** (no current firings at baseline)

---

## ✅ All Green = Ready for Fault Injection

| Layer | Verified |
|---|---|
| UI submits orders and shows all 4 deps healthy | ✅ |
| `correlation_id` propagates: UI → APIM → ADX → AKS → worker → Cosmos | ✅ |
| All 4 ADX tables (`AppLogs`, `AppSpans`, `AppExceptions`, `APIMGatewayLogs`) have live data | ✅ |
| All 5 Grafana dashboards show live zero-error baseline | ✅ |
| Log Analytics has AKS infra + PaaS diagnostic data (Cosmos, SB, Redis, KV, VM, Firewall) | ✅ |
| SRE Agent responds with real ADX data; custom agent and incident plan active | ✅ |
| All 5 alert rules exist and are at rest | ✅ |

**Next:** See `docs/fault-injection-guide.md` for the 8 fault injection scenarios.

# Azure SRE Agent setup

## 1. Resource creation

### 1a. Create Log Analytics Workspace

App Insights (workspace-based) requires a LAW as its backing store. Create it first:

1. Portal → **Log Analytics workspaces** → **+ Create**

| Field | Value |
|---|---|
| Subscription | `ME-MngEnv106333-kuchandr-1` |
| Resource group | `ai-obs-sre-demo` |
| Name | `aiosre-law-demo` |
| Region | `Australia East` |

2. Click **Review + Create → Create**. Wait for it to complete.

> **Why a dedicated LAW?** The LAW for App Insights only stores the SRE Agent's own operational logs (tool invocations, latency, errors). Keeping it separate from any shared LAW prevents agent noise from polluting application observability queries.

### 1b. Create Application Insights

1. Portal → **Application Insights** → **+ Create**

| Field | Value |
|---|---|
| Subscription | `ME-MngEnv106333-kuchandr-1` |
| Resource group | `ai-obs-sre-demo` |
| Name | `aiosre-appinsights-demo` |
| Region | `Australia East` |
| Resource Mode | Workspace-based |
| Log Analytics Workspace | `aiosre-law-demo` (created above) |

2. Click **Review + Create → Create**. Wait for it to complete.

> **Note on Application Insights:** this instance is for the SRE Agent's own operational telemetry (tool calls, query latency, errors). It is **not** where your application logs are stored — those flow via OTel → Event Hub → ADX. A separate App Insights for agent telemetry keeps operational noise out of your application observability data.

### 1c. Create SRE Agent

Navigate to **https://sre.azure.com/?create=true** and fill in:

| Field | Value |
|---|---|
| Agent name | `aiosre-sre-agent-demo` |
| Region | `Australia East` |
| Model provider | Anthropic (preferred) |
| Application Insights | **Use existing** → select `aiosre-appinsights-demo` |

Click **Review + Create → Deploy**.

> **Important — SRE Agent auto-creates its own UAMI.** The portal creates a new managed identity named `aiosre-sre-agent-demo-<suffix>`. This is **different** from `aiosre-sre-uami-demo` which was pre-provisioned by Bicep. You must grant ADX access to this new identity before the connector test will pass (see step 2 below).

**Actual identity created (this deployment):**

| Field | Value |
|---|---|
| Identity name | `aiosre-sre-agent-demo-dgkedbpaifx6o` |
| Principal ID | `d4d62be8-7ebe-45f3-b400-b21ffa2c5869` |
| Client ID | `811680b3-80da-4ede-9524-9bebf18dca2d` |

## 2. Grant RBAC to the SRE Agent identity

After the agent is deployed, find the auto-created identity name from the portal (SRE Agent → **Overview** → Managed identity) and run:

```powershell
# Replace <suffix> with the actual suffix shown in the portal
$principalId = az identity show -g ai-obs-sre-demo -n "aiosre-sre-agent-demo-<suffix>" --query principalId -o tsv

# 1) ADX Viewer on observability database
az kusto database-principal-assignment create `
  -g ai-obs-sre-demo `
  --cluster-name aiosreadxdemo4lrdqw `
  --database-name observability `
  --principal-assignment-name sre-agent-viewer `
  --principal-id $principalId `
  --principal-type App `
  --role Viewer

# 2) Reader + Monitoring Reader on the resource group
$rgId = az group show -n ai-obs-sre-demo --query id -o tsv
az role assignment create --assignee $principalId --role "Reader"             --scope $rgId
az role assignment create --assignee $principalId --role "Monitoring Reader"  --scope $rgId

# 3) Log Analytics Reader on the LAW workspace
az role assignment create --assignee $principalId --role "Log Analytics Reader" `
  --scope "/subscriptions/ba43c91f-2d76-4000-a7ad-24750cab54c3/resourceGroups/ai-obs-sre-demo/providers/Microsoft.OperationalInsights/workspaces/aiosre-la-demo"
```

**Verified grants for this deployment (`d4d62be8-7ebe-45f3-b400-b21ffa2c5869`):**

| Role | Scope |
|---|---|
| ADX Database Viewer | `observability` database |
| Reader | `ai-obs-sre-demo` resource group |
| Monitoring Reader | `ai-obs-sre-demo` resource group |
| Log Analytics Reader | `aiosre-la-demo` workspace |

## 3. Connector: Azure Data Explorer (Logs — Plane 1 + Plane 3b)

This connector covers:
- **Plane 1 — AKS application telemetry**: `AppLogs`, `AppSpans`, `AppExceptions` (OTel → Event Hub → ADX pipeline)
- **Plane 3b — APIM diagnostics**: `APIMGatewayLogs` (APIM log-to-eventhub → Event Hub → ADX)

Steps:
1. SRE Agent portal → **Builder** (left nav) → **Connectors** → **+ Add connector** → **Azure Data Explorer**
2. Fill in:

| Field | Value |
|---|---|
| Connector name | `sredemo-kusto-client` |
| Cluster URI | `https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net` |
| Database | `observability` |
| Auth | Managed Identity → `aiosre-sre-agent-demo-dgkedbpaifx6o` |
| Allow query tools | ✅ checked |

3. Click **Test connection** — must pass (ADX Viewer granted in step 2)
4. Click **Save**

**Status (this deployment): ✅ Connected**

## 4. Connector: Azure Monitor (Azure resources — Plane 3a + Plane 4 metrics)

This connector covers Azure Monitor **platform metrics** accessible via the ARM Metrics API:
- **Plane 3a — APIM platform metrics**: request rate, latency, 4xx/5xx
- **Plane 4 — PaaS metrics**: Cosmos DB RU/s, Service Bus queue depth, Redis evictions, Key Vault latency

> **AKS pod/node metrics are NOT in this connector.** Container Insights writes AKS platform data to Log Analytics (section 6 below).
>
> **Managed Prometheus (AMW) is NOT supported as an SRE Agent connector.** Prometheus is for Grafana PromQL dashboards only.

Steps:
1. SRE Agent portal → **Builder** → **Connectors** → **+ Add connector** → **Azure Monitor**
2. Fill in:

| Field | Value |
|---|---|
| Scope | Resource Group `ai-obs-sre-demo` |
| Auth | Managed Identity → `aiosre-sre-agent-demo-dgkedbpaifx6o` |

3. Click **Test connection** — must pass (`Monitoring Reader` already granted in step 2)
4. Click **Save**

## 4a. Create Azure Monitor Alert Rules (fires into SRE Agent)

These 5 alert rules cover all 8 fault scenarios. They fire as Azure Monitor alerts that the SRE Agent Incidents connector picks up and auto-investigates.

| Alert name | Type | Fault scenarios triggered |
|---|---|---|
| `apim-backend-errors` | Metric (APIM `Requests`, 5xx dimension) | Scenario 1 (backend fault), Scenario 2 (APIM rate limit) |
| `aks-pod-crashloop` | Log search (KubeEvents) | Scenario 7 (CPU saturation), Scenario 8 (bad deployment) |
| `aks-container-errors` | Log search (ContainerLog `LogEntry`) | Scenario 4 (OpenAI down), Scenario 5 (Speech down), Scenario 6 (3rd party) |
| `cosmos-connection-failures` | Log search (AppDependencies) | Scenario 3 (Cosmos PE/DNS fault) |
| `servicebus-dlq-spike` | Metric (SB `DeadletteredMessages`) | Scenarios 1, 3, 4, 5 (any worker failure) |

**Status (this deployment): ✅ All 5 created** via `az rest` (ARM API directly — `az monitor metrics alert create` fails for APIM with "Regional alert rule" error when using dimensions; use the REST method below instead).

```powershell
$sub   = 'ba43c91f-2d76-4000-a7ad-24750cab54c3'
$rg    = 'ai-obs-sre-demo'
$loc   = 'australiaeast'
$lawId = '/subscriptions/ba43c91f-2d76-4000-a7ad-24750cab54c3/resourceGroups/ai-obs-sre-demo/providers/Microsoft.OperationalInsights/workspaces/aiosre-la-demo'
$apimId = '/subscriptions/ba43c91f-2d76-4000-a7ad-24750cab54c3/resourceGroups/ai-obs-sre-demo/providers/Microsoft.ApiManagement/service/aiosre-apim-demo'
$sbId   = '/subscriptions/ba43c91f-2d76-4000-a7ad-24750cab54c3/resourceGroups/ai-obs-sre-demo/providers/Microsoft.ServiceBus/namespaces/aiosre-sb-demo-4lrdqw4e2yr2s'
$baseUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights"
$sqApi   = 'api-version=2022-06-15'
$maApi   = 'api-version=2018-03-01'

# Alert 1: APIM backend 5xx (metric alert — location=global required)
$a1 = @{ location='global'; properties=@{ description='APIM returning 5xx errors'; severity=2; enabled=$true
  scopes=@($apimId); evaluationFrequency='PT1M'; windowSize='PT5M'
  criteria=@{ 'odata.type'='Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    allOf=@(@{ criterionType='StaticThresholdCriterion'; name='BackendErrors'
      metricName='Requests'; metricNamespace='Microsoft.ApiManagement/service'
      dimensions=@(@{ name='BackendResponseCodeCategory'; operator='Include'; values=@('5xx') })
      operator='GreaterThan'; threshold=3; timeAggregation='Total' }) } } } | ConvertTo-Json -Depth 10 -Compress
$a1 | Out-File "$env:TEMP\a1.json" -Encoding utf8NoBOM
az rest --method PUT --uri "$baseUri/metricAlerts/apim-backend-errors?$maApi" --body "@$env:TEMP\a1.json" --headers "Content-Type=application/json" --query name -o tsv

# Alert 2: AKS pod crashloop (log search)
$a2 = @{ location=$loc; properties=@{ description='AKS pod crash loop or OOM'; severity=2; enabled=$true
  scopes=@($lawId); evaluationFrequency='PT5M'; windowSize='PT5M'
  criteria=@{ allOf=@(@{ query="KubeEvents | where TimeGenerated > ago(5m) | where Reason has_any ('BackOff','CrashLoopBackOff','OOMKilling') | count"
    timeAggregation='Count'; operator='GreaterThan'; threshold=2
    failingPeriods=@{ numberOfEvaluationPeriods=1; minFailingPeriodsToAlert=1 } }) } } } | ConvertTo-Json -Depth 10 -Compress
$a2 | Out-File "$env:TEMP\a2.json" -Encoding utf8NoBOM
az rest --method PUT --uri "$baseUri/scheduledQueryRules/aks-pod-crashloop?$sqApi" --body "@$env:TEMP\a2.json" --headers "Content-Type=application/json" --query name -o tsv

# Alert 3: AKS container errors (log search) — note: column is LogEntry not LogMessage
$a3 = @{ location=$loc; properties=@{ description='High error rate in AKS containers'; severity=2; enabled=$true
  scopes=@($lawId); evaluationFrequency='PT5M'; windowSize='PT5M'
  criteria=@{ allOf=@(@{ query="ContainerLog | where TimeGenerated > ago(5m) | where LogEntry has_any ('ERROR','Exception','Traceback','CRITICAL') | count"
    timeAggregation='Count'; operator='GreaterThan'; threshold=15
    failingPeriods=@{ numberOfEvaluationPeriods=1; minFailingPeriodsToAlert=1 } }) } } } | ConvertTo-Json -Depth 10 -Compress
$a3 | Out-File "$env:TEMP\a3.json" -Encoding utf8NoBOM
az rest --method PUT --uri "$baseUri/scheduledQueryRules/aks-container-errors?$sqApi" --body "@$env:TEMP\a3.json" --headers "Content-Type=application/json" --query name -o tsv

# Alert 4: Cosmos failures (log search via AppDependencies)
$a4 = @{ location=$loc; properties=@{ description='Cosmos DB dependency failures'; severity=1; enabled=$true
  scopes=@($lawId); evaluationFrequency='PT5M'; windowSize='PT5M'
  criteria=@{ allOf=@(@{ query="AppDependencies | where TimeGenerated > ago(5m) | where DependencyType has 'cosmosdb' or Target has 'cosmos' | where Success == false | count"
    timeAggregation='Count'; operator='GreaterThan'; threshold=3
    failingPeriods=@{ numberOfEvaluationPeriods=1; minFailingPeriodsToAlert=1 } }) } } } | ConvertTo-Json -Depth 10 -Compress
$a4 | Out-File "$env:TEMP\a4.json" -Encoding utf8NoBOM
az rest --method PUT --uri "$baseUri/scheduledQueryRules/cosmos-connection-failures?$sqApi" --body "@$env:TEMP\a4.json" --headers "Content-Type=application/json" --query name -o tsv

# Alert 5: Service Bus DLQ spike (metric alert)
$a5 = @{ location='global'; properties=@{ description='Service Bus dead-letter queue spike'; severity=2; enabled=$true
  scopes=@($sbId); evaluationFrequency='PT1M'; windowSize='PT5M'
  criteria=@{ 'odata.type'='Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    allOf=@(@{ criterionType='StaticThresholdCriterion'; name='DLQ'
      metricName='DeadletteredMessages'; metricNamespace='Microsoft.ServiceBus/namespaces'
      operator='GreaterThan'; threshold=5; timeAggregation='Maximum' }) } } } | ConvertTo-Json -Depth 10 -Compress
$a5 | Out-File "$env:TEMP\a5.json" -Encoding utf8NoBOM
az rest --method PUT --uri "$baseUri/metricAlerts/servicebus-dlq-spike?$maApi" --body "@$env:TEMP\a5.json" --headers "Content-Type=application/json" --query name -o tsv

Write-Host 'All 5 alert rules created.'
```

> **Note:** `az monitor metrics alert create` fails for APIM with "A Regional alert rule can only be created on a custom metric" when using `BackendResponseCode` dimension. Use `az rest --method PUT` with `location=global` as shown above.

> **No action group required.** Alerts in Fired state are visible to the SRE Agent Incidents connector automatically.

## 4b. Incident Platform: Azure Monitor

This makes the SRE Agent **auto-start an RCA investigation** when one of the above alerts fires during fault injection.

> **Prerequisites**: Section 4a alert rules created.

Steps:
1. SRE Agent portal → **Builder** → **Incident platform** (left nav)
2. **Incident platform** dropdown → select **Azure Monitor**
3. Click **Connect** — Azure Monitor connects automatically using the agent's UAMI (no extra auth needed since Monitoring Reader was granted in step 2)
4. Once connected, click **Create a response plan**
5. In the response plan, scope to resource group `ai-obs-sre-demo` and enable **Auto-investigate**

**Status (this deployment): ✅ Azure Monitor connected**

**Demo flow with this connector active:**
```
Fault injected
    ↓ (within 1-5 min)
Alert fires in Azure Monitor
    ↓
SRE Agent Incidents connector detects alert
    ↓
Agent auto-calls Kusto tools (QueryRecentAppErrors / QueryDependencyErrors / etc.)
    ↓
Agent posts RCA in chat: symptom → evidence chain → root cause → remediation
```

| Alert | Agent likely calls |
|---|---|
| `apim-backend-errors` | `APIMvsBackendCorrelation` → `QueryRecentAppErrors` |
| `aks-pod-crashloop` | `QueryRecentAppErrors` → `DeploymentCorrelation` |
| `aks-container-errors` | `QueryDependencyErrors` → `TraceDrilldown` |
| `cosmos-connection-failures` | `QueryDependencyErrors(cosmos)` → LAW Cosmos logs |
| `servicebus-deadletters` | `QueryRecentAppErrors` → `TraceDrilldown` |

## 5. Connector: Log Analytics (Plane 2 AKS platform + Plane 4 PaaS diagnostic logs)

This is the primary connector for both AKS infrastructure visibility and PaaS diagnostic logs.

**Plane 2 — AKS platform monitoring via Container Insights:**
- `KubePodInventory` — pod status, restarts, phase, node assignment
- `KubeNodeInventory` — node CPU/memory pressure, conditions
- `ContainerLog` / `ContainerLogV2` — pod stdout/stderr
- `KubeEvents` — OOMKilled, CrashLoopBackOff, BackOff events
- `Perf` — container CPU/memory utilisation timeseries

**Plane 4 — PaaS diagnostic logs:**
- Cosmos DB throttle errors, partition key warnings
- Service Bus dead-letter events, connection errors
- Redis connection failures, eviction events
- Key Vault access audit logs
- Azure Firewall deny logs
- VM syslog / Windows event logs

> **Which workspace to select:** Use **`aiosre-la-demo`** — this is where:
> - Bicep `diagnosticSettings` routes all PaaS logs (via `logAnalyticsWorkspaceId`)
> - Container Insights (omsagent addon) writes all AKS platform tables
>
> Do **not** select `aiosre-law-demo` — that is the backing store for the SRE Agent's own App Insights operational telemetry. The agent uses it internally; you don’t connect to it as an external data source.

Steps:
1. SRE Agent portal → **Builder** → **Connectors** → **+ Add connector** → **Log Analytics**
2. Fill in:

| Field | Value |
|---|---|
| Connector name | `law-connector` |
| Log Analytics workspace | `aiosre-la-demo` (ai-obs-sre-demo) |

3. Click **Test connection** → should pass
4. Click **Save**

**Status (this deployment): ✅ Connected**

## 6. Connector: GitHub (Code)

Allows the agent to correlate errors with source code, recent commits, and deployment changes.

1. SRE Agent portal → **Builder** → **Connectors** → **+ Add connector** → **GitHub**
2. Fill in:

| Field | Value |
|---|---|
| Repository URL | `https://github.com/kunalchandratre1/ai-observability-sre-demo` |
| PAT | Fine-grained PAT with `Contents: Read` + `Metadata: Read` |

3. Click **Save**

**Status (this deployment): ✅ Connected** (repo: `ai-observability-sre-demo`)

## 7. Knowledge Files (Knowledge sources)

Upload the fault scenario runbooks so the agent knows expected symptoms and remediation steps for each scenario.

1. SRE Agent portal → **Builder** → **Knowledge sources** → `+`
2. Upload all `.md` files from `docs/runbooks/`:
   - `01-backend-api-fault.md`
   - `02-apim-rate-limit.md`
   - `03-cosmos-private-endpoint.md`
   - `04-openai-down.md`
   - `05-speech-down.md`
   - `06-thirdparty-down.md`
   - `07-cpu-saturation.md`
   - `08-bad-deployment.md`
3. Click **Done and go to agent**

## 8. Kusto Tools (Skill builder)

Tools give the agent deterministic, parameterised KQL queries it can call during investigations.

**Location in portal:** SRE Agent → **Builder** → **Skill builder** → **+ Create skill**

> **This is NOT in Knowledge sources.** Skill builder is where executable KQL tools go. Knowledge sources is for reference documents (runbooks, postmortems).

**Steps:**
1. **Builder → Skill builder → + Create skill**
2. **Name:** `SRE Observability - ADX Kusto Tools`
3. **Files:** Click **Upload folder** → select the entire `infra/sre-agent/kusto-tools/` folder
   - This uploads all 6 `.kql` files + `SKILL.md`
   - The portal shows a root `SKILL.md (default)` in the file tree — click it and **replace** the template content with the content from `infra/sre-agent/kusto-tools/SKILL.md`
4. **Tools (right panel):** Expand **`sreagent-builtin-kusto-client`** → check all tools
5. Click **Create**

> The `SKILL.md` is the agent's instruction file — it tells the agent *when* to call each KQL file and what parameters to use. Without it populated, the agent won't invoke the right query for each scenario.

| Tool name | ADX tables queried | What it answers |
|---|---|---|
| `QueryRecentAppErrors` | `AppLogs`, `AppExceptions` | Recent errors by service and severity |
| `QueryDependencyErrors` | `AppSpans`, `AppExceptions` | Failures for a specific dependency (OpenAI / Speech / Cosmos / ThirdParty) |
| `QueryLatencyPercentiles` | `AppSpans` | p50/p95/p99 latency per service |
| `TraceDrilldown` | `AppSpans`, `AppLogs`, `AppExceptions` | Full trace timeline for a single `trace_id` |
| `APIMvsBackendCorrelation` | `APIMGatewayLogs`, `AppExceptions`, `AppSpans` | Joins APIM 5xx to backend exceptions via `x-correlation-id` / `traceparent` |
| `DeploymentCorrelation` | `AppLogs`, `AppSpans` | Error rate / latency shift correlated with `deployment_version` changes |

For each tool, declare typed parameters matching the `declare query_parameters(...)` block at the top of each `.kql` file.

## 9. Custom Agent: `SREObservabilityExpert`

> **Important — no spaces in agent name.** The portal does not allow spaces in the custom agent name field.

The custom agent packages your system prompt (Instructions), Skills, and Tools into a focused domain specialist. The parent SRE Agent orchestrates and hands off to this agent for all incident RCA work in `ai-obs-sre-demo`.

> **There is no standalone Instructions tab** for the main SRE Agent. The system prompt lives inside the custom agent's Instructions field.

**Navigate to:** SRE Agent portal → **Builder** → **Agent Canvas** → **Create** → **Custom Agent**

The portal shows a **Form / YAML** toggle. Use Form view (default).

### Step 1 — Name

| Field | Value |
|---|---|
| **Name** | `SREObservabilityExpert` |

> No spaces allowed. Do not use `SRE Observability Expert`.

### Step 2 — Instructions

1. Click in the **Instructions** text area
2. Paste the full contents of `infra/sre-agent/prompts/system-prompt.md`
3. Optionally click **Refine with AI** to let the portal suggest improvements (not required)

The instructions tell the agent:
- The 4-plane telemetry architecture (ADX primary, Azure Monitor for metrics, Prometheus for AKS, GitHub for code)
- The ID taxonomy (`correlation_id` PRIMARY join key, vs `trace_id`, vs `request_id`)
- The investigation recipe: which Kusto tool to call in which order for each fault type
- The required RCA output format (symptom → timeline → evidence chain → root cause → remediation)
- Confidence thresholds and NEVER rules (no logging request bodies, no invented correlation_ids)

### Step 3 — Skills

> The portal says: *"By default, this agent inherits 36 global skills. Selecting skills here will override the defaults."*

Leave this at **default** (do NOT click Choose skills). This means the agent inherits all global skills including `SRE Observability - ADX Kusto Tools` that you created in step 8.

> If you explicitly select skills here, you will override the defaults and must manually re-add every skill you want. Leave blank to inherit all.

### Step 4 — Tools

> The portal says: *"By default, this agent inherits 46 global tools. Selecting tools here will override the defaults."*

Leave this at **default** (do NOT click Choose tools). All 46 global tools including the Kusto client tools are inherited automatically.

### Step 5 — Hooks

Leave **Manage Hooks** blank (not required for this demo).

### Step 6 — Create

Click **Create**. The canvas will show a new node `SREObservabilityExpert`.

---

## 10. Incident Response Plan

This connects the Azure Monitor alert rules (step 4a) to the custom agent (step 9) so investigations start automatically when an alert fires.

The wizard has **2 steps**: Response plan → Incidents preview.

### Step 1 — Response plan

**Navigate to:** Builder → Agent Canvas → Create → Trigger → Incident response plan

| Field | Value | Notes |
|---|---|---|
| **Incident response plan name** | `SREFaultInvestigation` | No spaces |
| **Severity** | `Sev 1`, `Sev 2` | Required. Our 5 alert rules are severity 1 and 2. Select both. |
| **Title contains** | _(leave blank)_ | Leaving blank matches all alert titles. Optionally add `apim` / `aks` / `cosmos` to narrow scope. |
| **Title does not contain** | _(leave blank)_ | No exclusions needed |
| **Response subagent** | `SREObservabilityExpert` | Select from dropdown — this is the custom agent created in step 9 |
| **Agent autonomy level** | **Review** | Review = agent proposes actions, waits for your approval before executing. Safer for demo. Autonomous = agent acts immediately without approval. |

Click **Next**.

### Step 2 — Incidents preview

This step shows a preview of existing Azure Monitor alerts that match the filters you set. Verify that your 5 alert rules (`apim-backend-errors`, `aks-pod-crashloop`, `aks-container-errors`, `cosmos-connection-failures`, `servicebus-dlq-spike`) appear in the list (they may show as "No active incidents" if none are currently firing — that is expected).

Click **Create** (or **Save**).

**Expected canvas after this step:**
```
Incident Response Plan: SREFaultInvestigation
    ↓ (alert fires)
Custom Agent: SREObservabilityExpert
    ├─ Instructions: system-prompt.md (RCA recipe + output format)
    ├─ Skills: SRE Observability - ADX Kusto Tools (inherited global)
    └─ Tools: sreagent-builtin-kusto-client (inherited global)
```

**Demo flow:**
```
Fault injected
    ↓ (within 1–5 min)
Azure Monitor alert fires
    ↓
Incident platform connector picks up alert
    ↓
SREObservabilityExpert auto-investigates
    ↓
Calls QueryRecentAppErrors → QueryDependencyErrors → TraceDrilldown
    ↓
Posts structured RCA: symptom → evidence chain → root cause [confidence] → remediation
```

## 11. Smoke test

Ask the agent: *“Show me the most recent application errors in the last 30 minutes.”*

Expected behaviour:
1. Agent calls `QueryRecentAppErrors(30m, "api-service")`
2. Returns structured RCA with cited KQL and evidence from ADX
3. References AKS CPU/memory context from Azure Monitor if relevant

If the agent returns “no data found”, verify data is flowing:
```powershell
# Quick ADX row count check
$t = az account get-access-token --resource 'https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net' --query accessToken -o tsv
$body = '{ "db": "observability", "csl": "AppLogs | count" }'
$r = Invoke-WebRequest -Method POST -Uri 'https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net/v1/rest/query' -Headers @{ Authorization = "Bearer $t"; 'x-ms-client-request-id' = 'smoke;1' } -ContentType 'application/json; charset=utf-8' -Body $body
($r.Content | ConvertFrom-Json).Tables[0].Rows[0][0]
```

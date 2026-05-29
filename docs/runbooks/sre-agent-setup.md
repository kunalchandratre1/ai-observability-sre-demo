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

> **Important — SRE Agent auto-creates its own UAMI.** The portal creates a new managed identity named `aiosre-sre-agent-demo-<suffix>` (e.g. `aiosre-sre-agent-demo-dgkedbpaifx6o`). This is **different** from `aiosre-sre-uami-demo` which was pre-provisioned by Bicep. You must grant ADX access to this new identity before the connector test will pass (see step 2 below).

## 2. Grant ADX access to the SRE Agent identity

After the agent is deployed, find the auto-created identity name from the portal (SRE Agent → **Overview** → Managed identity) and run:

```powershell
# Replace <suffix> with the actual suffix shown in the portal
$sreAgentIdentityName = "aiosre-sre-agent-demo-<suffix>"
$principalId = az identity show -g ai-obs-sre-demo -n $sreAgentIdentityName --query principalId -o tsv

az kusto database-principal-assignment create `
  -g ai-obs-sre-demo `
  --cluster-name aiosreadxdemo4lrdqw `
  --database-name observability `
  --principal-assignment-name sre-agent-viewer `
  --principal-id $principalId `
  --principal-type App `
  --role Viewer
```

Also grant Reader + Monitoring Reader on the RG:

```powershell
$rgId = az group show -n ai-obs-sre-demo --query id -o tsv
az role assignment create --assignee $principalId --role "Reader"            --scope $rgId
az role assignment create --assignee $principalId --role "Monitoring Reader" --scope $rgId
```

## 3. Connector: Azure Data Explorer (Logs — Plane 1 + Plane 3b)

This connector covers:
- **Plane 1 — AKS application telemetry**: `AppLogs`, `AppSpans`, `AppExceptions` (OTel → Event Hub → ADX pipeline)
- **Plane 3b — APIM diagnostics**: `APIMGatewayLogs` (APIM log-to-eventhub → Event Hub → ADX)

Steps:
1. SRE Agent portal → **Full setup** → **Logs** → `+` → **Azure Data Explorer**
2. Fill in:

| Field | Value |
|---|---|
| Connector name | `sredemo-kusto-client` |
| Cluster URI | `https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net` |
| Database | `observability` |
| Auth | Managed Identity → `aiosre-sre-agent-demo-<suffix>` |
| Allow query tools | ✅ checked |

3. Click **Test connection** — must pass (step 2 grants granted ADX Viewer)
4. Click **Save**

## 4. Connector: Azure Monitor (Azure resources — Plane 3a + Plane 4 metrics)

This connector covers Azure Monitor **platform metrics** accessible via the ARM Metrics API:
- **Plane 3a — APIM platform metrics**: request rate, latency, 4xx/5xx
- **Plane 4 — PaaS metrics**: Cosmos DB RU/s, Service Bus queue depth, Redis evictions, Key Vault latency

> **AKS pod/node metrics are NOT in this connector.** Container Insights writes AKS platform data to Log Analytics (section 5 below) where the agent queries `KubePodInventory`, `KubeNodeInventory`, and `ContainerLog` tables via KQL.
>
> **Managed Prometheus (AMW) is NOT supported as an SRE Agent connector.** Prometheus is for Grafana PromQL dashboards only.

Steps:
1. SRE Agent portal → **Full setup** → **Azure resources** → `+`
2. Fill in:

| Field | Value |
|---|---|
| Scope | Resource Group `ai-obs-sre-demo` |
| Auth | Managed Identity → `aiosre-sre-agent-demo-<suffix>` |

3. Click **Test connection** — must pass (`Monitoring Reader` already granted in step 2)
4. Click **Save**

> **Skip Incidents** — requires ITSM integration (ServiceNow/Jira), not part of this demo.

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
1. SRE Agent portal → **Full setup** → **Logging providers** → `+` → **Log Analytics**
2. Fill in:

| Field | Value |
|---|---|
| Connector name | `sre-law-connector` |
| Log Analytics workspace | `aiosre-la-demo` (ai-obs-sre-demo) |

3. Click **Test connection** → should pass
4. Click **Save**

## 6. Connector: GitHub (Code)

Allows the agent to correlate errors with source code, recent commits, and deployment changes.

1. SRE Agent portal → **Full setup** → **Code** → `+` → **GitHub**
2. Fill in:

| Field | Value |
|---|---|
| Repository URL | `https://github.com/kunalchandratre1/ai-observability-sre-demo` |
| PAT | Fine-grained PAT with `Contents: Read` + `Metadata: Read` |

3. Click **Save**

## 7. Knowledge Files

Upload the fault scenario runbooks so the agent knows expected symptoms and remediation steps for each scenario.

1. SRE Agent portal → **Full setup** → **Knowledge files** → `+`
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

## 8. Kusto Tools

Tools give the agent deterministic, parameterised KQL queries it can call during investigations.
Upload each `.kql` file from `infra/sre-agent/kusto-tools/` via SRE Agent portal → **Tools** → **+ Add KQL tool**.

| Tool name | ADX tables queried | What it answers |
|---|---|---|
| `QueryRecentAppErrors` | `AppLogs`, `AppExceptions` | Recent errors by service and severity |
| `QueryDependencyErrors` | `AppSpans`, `AppExceptions` | Failures for a specific dependency (OpenAI / Speech / Cosmos / ThirdParty) |
| `QueryLatencyPercentiles` | `AppSpans` | p50/p95/p99 latency per service |
| `TraceDrilldown` | `AppSpans`, `AppLogs`, `AppExceptions` | Full trace timeline for a single `trace_id` |
| `APIMvsBackendCorrelation` | `APIMGatewayLogs`, `AppExceptions`, `AppSpans` | Joins APIM 5xx to backend exceptions via `x-correlation-id` / `traceparent` |
| `DeploymentCorrelation` | `AppLogs`, `AppSpans` | Error rate / latency shift correlated with `deployment_version` changes |

For each tool, declare typed parameters matching the `declare query_parameters(...)` block at the top of each `.kql` file.

## 9. System Prompt (Instructions)

1. SRE Agent portal → **Instructions** tab
2. Paste full contents of `infra/sre-agent/prompts/system-prompt.md`
3. Click **Save**

The system prompt tells the agent:
- the 4-plane telemetry architecture (what data is where)
- the ID taxonomy (`correlation_id` vs `trace_id` vs `request_id`)
- which Kusto tools to call for each fault scenario
- expected RCA output format (symptom → timeline → evidence chain → root cause → remediation)

## 10. Smoke test

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

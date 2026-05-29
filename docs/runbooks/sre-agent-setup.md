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

## 4. Connector: Azure Monitor (Azure resources — Plane 2 + Plane 3a + Plane 4)

This connector covers:
- **Plane 2 — AKS infra metrics**: pod/node CPU, memory, restarts → Azure Managed Prometheus (Azure Monitor workspace)
- **Plane 3a — APIM platform metrics**: request rate, latency, 4xx/5xx → Azure Monitor
- **Plane 4 — PaaS service logs/metrics**: Cosmos DB, Service Bus, Event Hub, Redis, Key Vault, Firewall, VM → Log Analytics / Azure Monitor

> Without this connector the agent can see application symptoms in ADX but cannot correlate with infra metrics or PaaS service health.

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

## 5. Connector: GitHub (Code)

Allows the agent to correlate errors with source code, recent commits, and deployment changes.

1. SRE Agent portal → **Full setup** → **Code** → `+` → **GitHub**
2. Fill in:

| Field | Value |
|---|---|
| Repository URL | `https://github.com/kunalchandratre1/ai-observability-sre-demo` |
| PAT | Fine-grained PAT with `Contents: Read` + `Metadata: Read` |

3. Click **Save**

## 6. Knowledge Files

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

## 7. Kusto Tools

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

## 8. System Prompt (Instructions)

1. SRE Agent portal → **Instructions** tab
2. Paste full contents of `infra/sre-agent/prompts/system-prompt.md`
3. Click **Save**

The system prompt tells the agent:
- the 4-plane telemetry architecture (what data is where)
- the ID taxonomy (`correlation_id` vs `trace_id` vs `request_id`)
- which Kusto tools to call for each fault scenario
- expected RCA output format (symptom → timeline → evidence chain → root cause → remediation)

## 9. Smoke test

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

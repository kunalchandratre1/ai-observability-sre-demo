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

The agent runs under the user-assigned managed identity `aiosre-sre-uami-demo` (provisioned by Bicep `identity.bicep`).

## 2. ADX connector
- Open the SRE Agent → **Connectors** → **+ Add** → **Azure Data Explorer**.
- Cluster URI: `https://<adx-cluster>.<region>.kusto.windows.net`
- Database: `observability`
- Auth: managed identity (the SRE UAMI already has **Database Viewer** role via `adx.bicep` `principalAssignments`).

## 3. Azure Monitor connector
- Add the **Azure Monitor** connector. Scope: subscription. The agent's UAMI must have `Monitoring Reader` at the resource group level (granted in `grafana.bicep`/`identity.bicep`; expand to the SRE UAMI if missing).

## 4. GitHub connector
- Add **GitHub** connector. Repo: `https://github.com/kunalchandratre1/ai-observability-sre-demo`.
- Use a fine-grained PAT with `Contents: Read` and `Metadata: Read`.

## 5. Kusto tools
Upload each `.kql` file under `infra/sre-agent/kusto-tools/` as a parameterised tool with the same name:
- QueryRecentAppErrors
- QueryDependencyErrors
- QueryLatencyPercentiles
- TraceDrilldown
- APIMvsBackendCorrelation
- DeploymentCorrelation

For each tool, declare the typed parameters that match `declare query_parameters(...)` at the top of the file.

## 6. System prompt
Copy `infra/sre-agent/prompts/system-prompt.md` into the agent's "Instructions" field. Save.

## 7. Smoke test
Ask the agent: *"Show me the most recent application errors in the last 30 minutes."*
You should see it call `QueryRecentAppErrors(30m, "api-service")` and return a structured RCA-style answer with cited KQL.

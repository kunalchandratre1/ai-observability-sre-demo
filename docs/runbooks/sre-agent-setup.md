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

## 3. ADX connector
- Open the SRE Agent → **Connectors** → **+ Add** → **Azure Data Explorer**.
- Cluster URI: `https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net`
- Database: `observability`
- Auth: Managed Identity → select `aiosre-sre-agent-demo-<suffix>`
- Click **Test connection** — should pass after step 2 above.

## 4. Azure Monitor connector
- Add the **Azure Monitor** connector. Scope: Resource Group `ai-obs-sre-demo`.
- Auth: Managed Identity → `aiosre-sre-agent-demo-<suffix>`
- The `Monitoring Reader` role was granted in step 2 above.

## 5. GitHub connector
- Add **GitHub** connector. Repo: `https://github.com/kunalchandratre1/ai-observability-sre-demo`.
- Use a fine-grained PAT with `Contents: Read` and `Metadata: Read`.

## 6. Kusto tools
Upload each `.kql` file under `infra/sre-agent/kusto-tools/` as a parameterised tool with the same name:
- QueryRecentAppErrors
- QueryDependencyErrors
- QueryLatencyPercentiles
- TraceDrilldown
- APIMvsBackendCorrelation
- DeploymentCorrelation

For each tool, declare the typed parameters that match `declare query_parameters(...)` at the top of the file.

## 7. System prompt
Copy `infra/sre-agent/prompts/system-prompt.md` into the agent's "Instructions" field. Save.

## 8. Smoke test
Ask the agent: *"Show me the most recent application errors in the last 30 minutes."*
You should see it call `QueryRecentAppErrors(30m, "api-service")` and return a structured RCA-style answer with cited KQL.

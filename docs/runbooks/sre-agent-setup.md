# Azure SRE Agent setup

## 1. Resource creation
- See `infra/scripts/50-create-sre-agent.sh`.
- The agent runs under the user-assigned managed identity `aiosre-sre-uami-demo` (provisioned by Bicep `identity.bicep`).

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

#!/usr/bin/env bash
# Provision Azure SRE Agent and connect ADX + GitHub repo.
# NOTE: Azure SRE Agent is in preview and provisioned via portal/CLI extension.
# This script orchestrates the supported commands; some steps are documented as portal actions.
set -euo pipefail
: "${RG:?}"; : "${LOCATION:=australiaeast}"
: "${SRE_AGENT_NAME:=aiosre-sre-agent-demo}"
: "${ADX_CLUSTER_URI:?}"; : "${ADX_DB:=observability}"
: "${SRE_UAMI:?SRE Agent UAMI name (kept under same RG)}"
: "${GITHUB_REPO_URL:=https://github.com/kunalchandratre1/ai-observability-sre-demo}"

echo "1) Register provider..."
az provider register --namespace Microsoft.SiteReliabilityEngineering --wait || true

echo "2) Create SRE Agent (preview API)..."
az rest --method put \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.SiteReliabilityEngineering/sreAgents/$SRE_AGENT_NAME?api-version=2024-10-01-preview" \
  --body "{
    \"location\":\"$LOCATION\",
    \"identity\":{\"type\":\"UserAssigned\",\"userAssignedIdentities\":{\"$(az identity show -g $RG -n $SRE_UAMI --query id -o tsv)\":{}}},
    \"properties\":{}
  }" || echo "(continue if preview API not available in your subscription)"

echo "3) Grant SRE Agent managed identity ADX Database Viewer role..."
# The SRE Agent creates an app registration whose principal ID must be granted
# Viewer on the ADX database. We discover it from the agent's identity object.
SRE_AGENT_PRINCIPAL=$(az rest \
  --method get \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.App/agents/$SRE_AGENT_NAME?api-version=2024-10-01-preview" \
  --query "identity.principalId" -o tsv 2>/dev/null || echo "")

if [[ -z "$SRE_AGENT_PRINCIPAL" ]]; then
  echo "  WARNING: Could not auto-detect SRE Agent principal ID via REST."
  echo "  To fix manually: Portal -> SRE Agent -> Overview -> note the App (client) ID"
  echo "  Then run:"
  echo "    ADX_CLUSTER=\$(az kusto cluster list -g $RG --query '[0].name' -o tsv)"
  echo "    az kusto database-principal-assignment create \\"
  echo "      --cluster-name \$ADX_CLUSTER --database-name $ADX_DB \\"
  echo "      --resource-group $RG --principal-assignment-name sre-agent-viewer \\"
  echo "      --principal-id <APP_CLIENT_ID> --principal-type App --role Viewer"
else
  ADX_CLUSTER=$(az kusto cluster list -g "$RG" --query '[0].name' -o tsv)
  echo "  SRE Agent principal: $SRE_AGENT_PRINCIPAL"
  echo "  Granting Viewer on $ADX_CLUSTER/$ADX_DB ..."
  az kusto database-principal-assignment create \
    --cluster-name "$ADX_CLUSTER" \
    --database-name "$ADX_DB" \
    --resource-group "$RG" \
    --principal-assignment-name "sre-agent-viewer" \
    --principal-id "$SRE_AGENT_PRINCIPAL" \
    --principal-type "App" \
    --role "Viewer" 2>/dev/null || echo "  (assignment already exists)"
  echo "  ADX Viewer granted."
fi

echo ""
echo "  NOTE: If the SRE Agent connector shows 403-Forbidden after setup,"
echo "  re-run this step with the App client ID shown in the connector error message:"
echo "    az kusto database-principal-assignment create \\"
echo "      --cluster-name \$(az kusto cluster list -g $RG --query '[0].name' -o tsv) \\"
echo "      --database-name $ADX_DB --resource-group $RG \\"
echo "      --principal-assignment-name sre-agent-viewer \\"
echo "      --principal-id <CLIENT_ID_FROM_403_ERROR> --principal-type App --role Viewer"

echo "4) Configure ADX connector (portal step):"
echo "   - Open SRE Agent -> Connectors -> Add ADX -> select cluster $ADX_CLUSTER_URI / db $ADX_DB"
echo "   - ADX Viewer permission already granted above (step 3)"

echo "5) Connect GitHub repo: $GITHUB_REPO_URL (paste PAT in portal)"

echo "6) Upload Kusto tools from /infra/sre-agent/kusto-tools/*.kql"
ls "$(dirname "$0")/../sre-agent/kusto-tools" || true

echo "Done. Continue manual steps in docs/runbooks/sre-agent-setup.md"

#!/usr/bin/env bash
# Provision Azure SRE Agent and connect ADX + GitHub repo.
# NOTE: Azure SRE Agent is in preview and provisioned via portal/CLI extension.
# This script orchestrates the supported commands; some steps are documented as portal actions.
set -euo pipefail
: "${RG:?}"; : "${LOCATION:=eastus}"
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

echo "3) Configure ADX connector (portal step):"
echo "   - Open SRE Agent -> Connectors -> Add ADX -> select cluster $ADX_CLUSTER_URI / db $ADX_DB"
echo "   - Use UAMI principal as auth (it already has Database Viewer role)"

echo "4) Connect GitHub repo: $GITHUB_REPO_URL (paste PAT in portal)"

echo "5) Upload Kusto tools from /infra/sre-agent/kusto-tools/*.kql"
ls "$(dirname "$0")/../sre-agent/kusto-tools" || true

echo "Done. Continue manual steps in docs/runbooks/sre-agent-setup.md"

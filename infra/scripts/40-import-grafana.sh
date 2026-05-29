#!/usr/bin/env bash
# Imports Grafana datasources (ADX + Azure Monitor) and dashboard JSONs.
# NOTE: On Windows use 40-import-grafana.ps1 instead.
set -euo pipefail
: "${RG:?}"; : "${GRAFANA:?Azure Managed Grafana resource name}"
: "${ADX_URI:?https://CLUSTER.REGION.kusto.windows.net}"; : "${ADX_DB:=observability}"
: "${SUB:?Subscription id}"
: "${LAW_RESOURCE_ID:?/subscriptions/.../resourceGroups/.../providers/Microsoft.OperationalInsights/workspaces/...}"

GRAFANA_HOST=$(az grafana show -g "$RG" -n "$GRAFANA" --query properties.endpoint -o tsv)
TOKEN=$(az account get-access-token --resource "https://grafana.azure.com" --query accessToken -o tsv)

# Helper
post_ds() {
  local body="$1"
  curl -fsSL -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$GRAFANA_HOST/api/datasources" -d "$body" || true
}

post_ds "$(jq -n --arg uri "$ADX_URI" --arg db "$ADX_DB" '{name:"ADX", type:"grafana-azure-data-explorer-datasource", access:"proxy", jsonData:{clusterUrl:$uri, defaultDatabase:$db}, secureJsonData:{}}')"
post_ds "$(jq -n --arg sub "$SUB" '{name:"AzureMonitor", type:"grafana-azure-monitor-datasource", access:"proxy", isDefault:true, jsonData:{subscriptionId:$sub, azureAuthType:"msi"}, secureJsonData:{}}')"

# Import dashboards (substitute LAW_RESOURCE_ID placeholder for Container Insights panel in D1)
SCRIPT_DIR="$(dirname "$0")"
for f in "$SCRIPT_DIR"/../grafana/dashboards/*.json; do
  CONTENT=$(sed "s|{{LAW_RESOURCE_ID}}|${LAW_RESOURCE_ID}|g; s|{{SUBSCRIPTION_ID}}|${SUB}|g" "$f")
  curl -fsSL -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$GRAFANA_HOST/api/dashboards/db" -d "{\"dashboard\":${CONTENT},\"overwrite\":true,\"folderId\":0}" || true
done
echo "Grafana imports complete: $GRAFANA_HOST"

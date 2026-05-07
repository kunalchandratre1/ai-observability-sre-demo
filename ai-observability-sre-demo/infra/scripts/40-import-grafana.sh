#!/usr/bin/env bash
# Imports Grafana datasources (ADX + Azure Monitor + Prometheus) and dashboard JSONs.
set -euo pipefail
: "${RG:?}"; : "${GRAFANA:?Azure Managed Grafana resource name}"
: "${ADX_URI:?https://CLUSTER.REGION.kusto.windows.net}"; : "${ADX_DB:=observability}"
: "${AMW:?Azure Monitor workspace name (Managed Prometheus)}"; : "${SUB:?Subscription id}"

GRAFANA_HOST=$(az grafana show -g "$RG" -n "$GRAFANA" --query properties.endpoint -o tsv)
TOKEN=$(az account get-access-token --resource "https://grafana.azure.com" --query accessToken -o tsv)

# Helper
post_ds() {
  local body="$1"
  curl -fsSL -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$GRAFANA_HOST/api/datasources" -d "$body" || true
}

post_ds "$(jq -n --arg uri "$ADX_URI" --arg db "$ADX_DB" '{name:"ADX", type:"grafana-azure-data-explorer-datasource", access:"proxy", jsonData:{clusterUrl:$uri, defaultDatabase:$db}, secureJsonData:{}}')"
post_ds "$(jq -n --arg sub "$SUB" '{name:"AzureMonitor", type:"grafana-azure-monitor-datasource", access:"proxy", jsonData:{subscriptionId:$sub, azureAuthType:"msi"}, secureJsonData:{}}')"
post_ds "$(jq -n --arg amw "$AMW" '{name:"Prometheus-AMW", type:"prometheus", access:"proxy", url:"https://" + $amw + ".prometheus.monitor.azure.com", jsonData:{httpMethod:"POST", azureCredentials:{authType:"msi"}}}')"

# Import dashboards
for f in "$(dirname "$0")"/../grafana/dashboards/*.json; do
  curl -fsSL -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$GRAFANA_HOST/api/dashboards/db" -d "{\"dashboard\":$(cat "$f"),\"overwrite\":true,\"folderId\":0}" || true
done
echo "Grafana imports complete: $GRAFANA_HOST"

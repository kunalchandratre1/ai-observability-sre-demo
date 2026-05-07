#!/usr/bin/env bash
# ADX bootstrap: applies schema.kql, then creates Event Hub Data Connections
# for both `aks-otel` (AppLogs/AppSpans) and `apim-diag` (APIMGatewayLogs).
#
# Required env (export before running):
#   RG, ADX_CLUSTER, ADX_DB, EHNS, AKS_OTEL_HUB, APIM_DIAG_HUB
set -euo pipefail

: "${RG:?}"; : "${ADX_CLUSTER:?}"; : "${ADX_DB:?}"; : "${EHNS:?}"
: "${AKS_OTEL_HUB:=aks-otel}"; : "${APIM_DIAG_HUB:=apim-diag}"

echo "[1/3] Applying schema.kql to $ADX_CLUSTER/$ADX_DB ..."
az kusto script create \
  --cluster-name "$ADX_CLUSTER" --database-name "$ADX_DB" --resource-group "$RG" \
  --name "schema-$(date +%s)" \
  --script-content @"$(dirname "$0")/../adx/schema.kql" \
  --continue-on-errors false

EH_NS_ID=$(az eventhubs namespace show -g "$RG" -n "$EHNS" --query id -o tsv)

echo "[2/3] Creating Data Connection for AKS OTel hub..."
az kusto data-connection event-hub create \
  --resource-group "$RG" --cluster-name "$ADX_CLUSTER" --database-name "$ADX_DB" \
  --data-connection-name "aks-otel-logs" \
  --location "$(az group show -n "$RG" --query location -o tsv)" \
  --consumer-group "adx" \
  --event-hub-resource-id "$EH_NS_ID/eventhubs/$AKS_OTEL_HUB" \
  --table-name "AppLogs" --mapping-rule-name "AppLogsMapping" --data-format "MULTIJSON" \
  --managed-identity-resource-id "$(az kusto cluster show -g "$RG" -n "$ADX_CLUSTER" --query identity.principalId -o tsv)" || true

az kusto data-connection event-hub create \
  --resource-group "$RG" --cluster-name "$ADX_CLUSTER" --database-name "$ADX_DB" \
  --data-connection-name "aks-otel-spans" \
  --location "$(az group show -n "$RG" --query location -o tsv)" \
  --consumer-group "adx" \
  --event-hub-resource-id "$EH_NS_ID/eventhubs/$AKS_OTEL_HUB" \
  --table-name "AppSpans" --mapping-rule-name "AppSpansMapping" --data-format "MULTIJSON" \
  --managed-identity-resource-id "$(az kusto cluster show -g "$RG" -n "$ADX_CLUSTER" --query identity.principalId -o tsv)" || true

echo "[3/3] Creating Data Connection for APIM diagnostics hub..."
az kusto data-connection event-hub create \
  --resource-group "$RG" --cluster-name "$ADX_CLUSTER" --database-name "$ADX_DB" \
  --data-connection-name "apim-diag" \
  --location "$(az group show -n "$RG" --query location -o tsv)" \
  --consumer-group "adx" \
  --event-hub-resource-id "$EH_NS_ID/eventhubs/$APIM_DIAG_HUB" \
  --table-name "APIMGatewayLogs" --mapping-rule-name "APIMGatewayLogsMapping" --data-format "MULTIJSON" \
  --managed-identity-resource-id "$(az kusto cluster show -g "$RG" -n "$ADX_CLUSTER" --query identity.principalId -o tsv)" || true

echo "ADX bootstrap complete."

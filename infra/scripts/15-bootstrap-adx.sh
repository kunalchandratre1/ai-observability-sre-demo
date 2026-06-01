#!/usr/bin/env bash
# ============================================================================
# 15-bootstrap-adx.sh
# Bootstrap ADX schema, ingestion mappings, update policies, and Event Hub
# data connections for the ai-observability-sre-demo stack.
#
# Changes vs original:
#   - Replaces experimental `az kusto data-connection` with `az rest` ARM PUT
#   - Uses `managedIdentityResourceId` = ADX cluster resource ID (not principalId)
#   - Single data connection for aks-otel → RawAksOtel (update policies fan-out
#     to AppLogs/AppSpans), eliminating the shared consumer-group bug
#   - Grants ADX cluster MI "Azure Event Hubs Data Receiver" on the EH namespace
#   - Applies schema.kql via Kusto management REST API (no CLI script create)
#
# Prerequisites:
#   az login (or service principal env vars set)
#   RG, ADX_CLUSTER, ADX_DB, EHNS exported (or defaults used below)
# ============================================================================
set -euo pipefail

RG="${RG:-ai-obs-sre-demo}"
ADX_DB="${ADX_DB:-observability}"
AKS_OTEL_HUB="${AKS_OTEL_HUB:-aks-otel}"
APIM_DIAG_HUB="${APIM_DIAG_HUB:-apim-diag}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUB=$(az account show --query id -o tsv)

# Auto-detect ADX cluster and EH namespace from resource group if not set
if [[ -z "${ADX_CLUSTER:-}" ]]; then
    ADX_CLUSTER=$(az kusto cluster list -g "$RG" -o json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['name'])")
    echo "  Auto-detected ADX cluster: $ADX_CLUSTER"
fi
if [[ -z "${EHNS:-}" ]]; then
    EHNS=$(az eventhubs namespace list -g "$RG" -o json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['name'])")
    echo "  Auto-detected EH namespace: $EHNS"
fi

EH_NS_ID=$(az eventhubs namespace show -g "$RG" -n "$EHNS" --query id -o tsv)
ADX_RES_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Kusto/clusters/$ADX_CLUSTER"
ADX_MI_OID=$(az kusto cluster show -g "$RG" -n "$ADX_CLUSTER" --query identity.principalId -o tsv 2>/dev/null)
# Use cluster's actual URI from Azure (avoids hardcoding region)
KUSTO_URI=$(az kusto cluster show -g "$RG" -n "$ADX_CLUSTER" --query uri -o tsv)
LOC=$(az kusto cluster show -g "$RG" -n "$ADX_CLUSTER" --query location -o tsv)

echo "=== ADX Bootstrap =================================================="
echo "RG           : $RG"
echo "ADX Cluster  : $ADX_CLUSTER / $ADX_DB  ($KUSTO_URI)"
echo "EH Namespace : $EHNS"
echo "ADX MI OID   : $ADX_MI_OID"
echo "===================================================================="

# ── Step 1: Create consumer groups ──────────────────────────────────────────
echo ""
echo "[1/4] Creating Event Hub consumer groups..."
az eventhubs eventhub consumer-group create -g "$RG" --namespace-name "$EHNS" \
    --eventhub-name "$AKS_OTEL_HUB" --name adx 2>/dev/null || echo "  adx cg on $AKS_OTEL_HUB: already exists"
az eventhubs eventhub consumer-group create -g "$RG" --namespace-name "$EHNS" \
    --eventhub-name "$APIM_DIAG_HUB" --name adx 2>/dev/null || echo "  adx cg on $APIM_DIAG_HUB: already exists"

# ── Step 2: Grant ADX MI Event Hubs Data Receiver ───────────────────────────
echo ""
echo "[2/4] Granting ADX cluster MI 'Azure Event Hubs Data Receiver' on EH namespace..."
az role assignment create \
    --assignee "$ADX_MI_OID" \
    --role "a638d3c7-ab3a-418d-83e6-5f17a39d4fde" \
    --scope "$EH_NS_ID" 2>/dev/null || echo "  Role assignment already exists or pending"

# ── Step 3: Apply schema via Kusto REST API ──────────────────────────────────
echo ""
echo "[3/4] Applying ADX schema..."
KUSTO_URI="https://$ADX_CLUSTER.$LOC.kusto.windows.net"
KUSTO_TOKEN=$(az account get-access-token --resource "https://help.kusto.windows.net" --query accessToken -o tsv)

run_kql() {
    local label="$1"
    local csl="$2"
    local body
    body=$(printf '{"db":"%s","csl":%s}' "$ADX_DB" "$(printf '%s' "$csl" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$KUSTO_URI/v1/rest/mgmt" \
        -H "Authorization: Bearer $KUSTO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body")
    if [[ "$http_code" == "200" ]]; then
        echo "  OK: $label"
    else
        echo "  WARN ($http_code): $label"
    fi
}

# Apply each KQL command from schema.kql individually
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^// ]] && continue
    [[ -z "${line// }" ]] && continue
    echo "  Executing: ${line:0:70}..."
    run_kql "${line:0:60}" "$line" || true
done < <(python3 - <<'PYEOF'
import re, sys, os
schema_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../adx/schema.kql")
text = open(schema_path).read()
# Split on blank lines between commands; keep multi-line KQL blocks together
commands = re.split(r'\n(?=\.)', text)
for cmd in commands:
    cmd = cmd.strip()
    if cmd and not cmd.startswith("//"):
        # Collapse to single line for REST API (inline KQL)
        single = ' '.join(line.strip() for line in cmd.splitlines() if not line.strip().startswith('//'))
        if single:
            print(single)
PYEOF
)

echo "  Schema applied (check warnings above for any issues)"

# Ingestion batching: 1 min for demo responsiveness (default is 5 min)
BATCH='{"MaximumBatchingTimeSpan":"00:01:00","MaximumNumberOfItems":500,"MaximumRawDataSizeMB":1024}'
run_kql "RawAksOtel batching" ".alter table RawAksOtel policy ingestionbatching '${BATCH}'"
run_kql "RawApimDiag batching" ".alter table RawApimDiag policy ingestionbatching '${BATCH}'"
run_kql "APIMGatewayLogs batching" ".alter table APIMGatewayLogs policy ingestionbatching '${BATCH}'"

# ── Step 4: Create data connections ─────────────────────────────────────────
echo ""
echo "[4/4] Creating ADX data connections..."

BASE_URL="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Kusto/clusters/$ADX_CLUSTER/databases/$ADX_DB/dataConnections"
API_VER="2023-08-15"

create_dc() {
    local name="$1" hub="$2" table="$3" mapping="$4"
    local body
    body=$(cat <<EOF
{
  "kind": "EventHub",
  "location": "$LOC",
  "properties": {
    "eventHubResourceId": "$EH_NS_ID/eventhubs/$hub",
    "consumerGroup": "adx",
    "tableName": "$table",
    "mappingRuleName": "$mapping",
    "dataFormat": "JSON",
    "managedIdentityResourceId": "$ADX_RES_ID",
    "compression": "None",
    "databaseRouting": "Single"
  }
}
EOF
)
    echo -n "  [$name] hub=$hub table=$table..."
    local http_code
    http_code=$(curl -s -o /tmp/dc_out.json -w "%{http_code}" \
        -X PUT "$BASE_URL/$name?api-version=$API_VER" \
        -H "Authorization: Bearer $(az account get-access-token --query accessToken -o tsv)" \
        -H "Content-Type: application/json" \
        -d "$body")
    local state
    state=$(python3 -c "import json; d=json.load(open('/tmp/dc_out.json')); print(d.get('properties',{}).get('provisioningState','?'))" 2>/dev/null || echo "?")
    echo " $http_code / $state"
}

create_dc "aks-otel-raw"    "$AKS_OTEL_HUB"  "RawAksOtel"      "RawAksOtelMapping"
create_dc "apim-diag-logs"  "$APIM_DIAG_HUB" "APIMGatewayLogs" "APIMGatewayLogsMapping"

echo ""
echo "=== Bootstrap complete. Data connections provision asynchronously (1-5 min). ==="
echo "Verify with:"
echo "  az rest --method GET --url 'https://management.azure.com$ADX_RES_ID/databases/$ADX_DB/dataConnections?api-version=$API_VER'"

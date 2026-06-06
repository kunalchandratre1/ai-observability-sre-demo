#!/usr/bin/env bash
# =============================================================================
# 70-seed-demo-data.sh
# Pre-demo data seeder — run this in Azure Cloud Shell before a customer demo
# to populate the Grafana Golden Signals and APIM Health dashboards with
# realistic exception data that has CorrelationId, DependencyName, and TraceId.
#
# Usage:
#   export APIM_GW_URL="https://aiosre-apim-demo.azure-api.net"
#   export APIM_KEY="<your-apim-subscription-key>"
#   bash 70-seed-demo-data.sh
#
# Optional env vars:
#   ORDERS_PER_FAULT  - orders per fault scenario (default: 5)
#   SKIP_WAIT         - set to "1" to skip the 60s ADX ingestion wait
# =============================================================================
set -euo pipefail

APIM_GW_URL="${APIM_GW_URL:-https://aiosre-apim-demo.azure-api.net}"
APIM_KEY="${APIM_KEY:?'APIM_KEY is required. Set it or copy infra/scripts/.env.example to .env and source it.'}"
ORDERS_PER_FAULT="${ORDERS_PER_FAULT:-5}"
SKIP_WAIT="${SKIP_WAIT:-0}"
SEED=$(date +"%y%m%d-%H%M")

BASE="${APIM_GW_URL%/}"
FAULT_URL="$BASE/voice/admin/faults"
ORDER_URL="$BASE/voice/orders"

log()   { echo -e "\033[0;36m$*\033[0m"; }
warn()  { echo -e "\033[0;33m  $*\033[0m"; }
ok()    { echo -e "\033[0;32m  $*\033[0m"; }
gray()  { echo -e "\033[0;90m  $*\033[0m"; }
title() { echo -e "\033[1;33m--- $* ---\033[0m"; }

# ── Helper: toggle a fault field ────────────────────────────────────────────
set_fault() {
    local payload="$1"
    curl -sf -X POST "$FAULT_URL" \
        -H "Ocp-Apim-Subscription-Key: $APIM_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || warn "fault toggle returned non-2xx (may be expected)"
}

# ── Helper: send N orders with a correlation-id prefix ─────────────────────
send_orders() {
    local scenario="$1"
    local count="$2"
    for i in $(seq 1 "$count"); do
        local cid="demo-${scenario}-${SEED}-${i}"
        curl -sf -X POST "$ORDER_URL" \
            -H "Ocp-Apim-Subscription-Key: $APIM_KEY" \
            -H "Content-Type: application/json" \
            -H "x-correlation-id: $cid" \
            -d '{"text":"order a flat white for demo run '"$i"'","user_id":"demo-seeder"}' \
            > /dev/null 2>&1 || true   # 503 is expected when fault is on
        gray "[$i/$count] cid=$cid"
        sleep 0.5
    done
}

# ── Main ────────────────────────────────────────────────────────────────────
echo ""
log "======================================================"
log "  SRE Demo — Pre-demo Data Seeder"
log "  APIM    : $BASE"
log "  Orders  : $ORDERS_PER_FAULT per fault scenario"
log "  Seed    : $SEED (prefix on all CorrelationIds)"
log "======================================================"

# Scenario 1: OpenAI down
echo ""
title "Scenario 1/3: AzureOpenAI dependency down"
echo "  [1/3] Enabling fault..."
set_fault '{"fault_force_openai_down":true}'
sleep 2
echo "  [2/3] Sending $ORDERS_PER_FAULT orders..."
send_orders "openai-down" "$ORDERS_PER_FAULT"
echo "  [3/3] Disabling fault..."
set_fault '{"fault_force_openai_down":false}'
sleep 3

# Scenario 2: Speech down
echo ""
title "Scenario 2/3: AzureSpeech dependency down"
echo "  [1/3] Enabling fault..."
set_fault '{"fault_force_speech_down":true}'
sleep 2
echo "  [2/3] Sending $ORDERS_PER_FAULT orders..."
send_orders "speech-down" "$ORDERS_PER_FAULT"
echo "  [3/3] Disabling fault..."
set_fault '{"fault_force_speech_down":false}'
sleep 3

# Scenario 3: Cosmos DNS break
echo ""
title "Scenario 3/3: Cosmos DNS break (Private Endpoint fault)"
echo "  [1/3] Enabling fault..."
set_fault '{"fault_force_cosmos_dns_break":true}'
sleep 2
echo "  [2/3] Sending $ORDERS_PER_FAULT orders..."
send_orders "cosmos-dns-break" "$ORDERS_PER_FAULT"
echo "  [3/3] Disabling fault..."
set_fault '{"fault_force_cosmos_dns_break":false}'
sleep 3

# Healthy baseline traffic
echo ""
title "Healthy baseline traffic (10 orders, no fault)"
for i in $(seq 1 10); do
    cid="demo-healthy-${SEED}-${i}"
    curl -sf -X POST "$ORDER_URL" \
        -H "Ocp-Apim-Subscription-Key: $APIM_KEY" \
        -H "Content-Type: application/json" \
        -H "x-correlation-id: $cid" \
        -d '{"text":"order a green tea for seat '"$i"'","user_id":"demo-seeder"}' \
        > /dev/null 2>&1 || true
    gray "[$i/10] cid=$cid"
    sleep 0.4
done

# Wait for ADX ingestion
if [[ "$SKIP_WAIT" != "1" ]]; then
    echo ""
    title "Waiting 60s for ADX ingestion pipeline"
    for s in 60 50 40 30 20 10; do
        gray "$s seconds remaining..."
        sleep 10
    done
fi

# ADX row count verification (requires az login)
echo ""
title "Verifying data in ADX"
if command -v az &>/dev/null; then
    ADX_URI=$(az kusto cluster list -g ai-obs-sre-demo -o json 2>/dev/null | python3 -c "import sys,json; c=json.load(sys.stdin); print(c[0]['uri'])" 2>/dev/null || echo "https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net")
    ADX_TOKEN=$(az account get-access-token --resource "https://help.kusto.windows.net" --query accessToken -o tsv 2>/dev/null || echo "")
    if [[ -n "$ADX_TOKEN" ]]; then
        for scenario in "openai-down" "speech-down" "cosmos-dns-break"; do
            prefix="demo-${scenario}-${SEED}"
            KQL="AppExceptions | where Timestamp > ago(30m) | where CorrelationId startswith '${prefix}' | summarize n=count() by DependencyName, ExceptionType"
            RESULT=$(curl -sf -X POST "$ADX_URI/v1/rest/query" \
                -H "Authorization: Bearer $ADX_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"db\":\"observability\",\"csl\":\"$KQL\"}" 2>/dev/null | \
                python3 -c "import sys,json; d=json.load(sys.stdin); rows=d['Tables'][0]['Rows']; [print('    DepName={} Type={} count={}'.format(r[0],r[1],r[2])) for r in rows] if rows else print('    no rows yet (ingestion may still be in progress)')" 2>/dev/null || echo "    parse error")
            echo "  $scenario: $RESULT"
        done
    else
        warn "ADX verify skipped (not logged in to az)"
    fi
else
    warn "ADX verify skipped (az CLI not found)"
fi

# Summary
echo ""
log "======================================================"
ok "Seeding complete!"
echo ""
ok "Open Grafana and check:"
ok "  D1 Golden Signals -> 'Top recent exceptions'"
ok "     Use correlation_id filter prefix: demo-*-$SEED-*"
ok "  D2 APIM Health    -> 'APIM 5xx joined with AppExceptions'"
echo ""
ok "  CorrelationId prefixes generated:"
echo "    demo-openai-down-$SEED-1 ... $ORDERS_PER_FAULT"
echo "    demo-speech-down-$SEED-1 ... $ORDERS_PER_FAULT"
echo "    demo-cosmos-dns-break-$SEED-1 ... $ORDERS_PER_FAULT"
log "======================================================"

#!/usr/bin/env bash
# Toggle a fault on the running deployment.
# Usage: 60-fault-toggle.sh openai-down on|off
#        60-fault-toggle.sh speech-down on|off
#        60-fault-toggle.sh thirdparty-down on|off
#        60-fault-toggle.sh cosmos-dns-break on|off
#        60-fault-toggle.sh cosmos-throttle on|off   # drops Cosmos to 400 RU (already at limit) then bursts load to trigger 429s
#        60-fault-toggle.sh cpu-burn <ms>
#        60-fault-toggle.sh exception on|off
#        60-fault-toggle.sh apim-rate-limit on|off
set -euo pipefail
: "${APIM_GW_URL:?https://APIM.azure-api.net}"
: "${APIM_KEY:?Subscription key for APIM voice-orders product}"

scenario="${1:?}"; arg="${2:?}"

case "$scenario" in
  openai-down|speech-down|thirdparty-down|cosmos-dns-break|exception)
    val=false; [[ "$arg" == "on" ]] && val=true
    field="fault_force_${scenario//-/_}"
    [[ "$scenario" == "cosmos-dns-break" ]] && field="fault_force_cosmos_dns_break"
    curl -fsSL -X POST -H "Ocp-Apim-Subscription-Key: $APIM_KEY" -H "Content-Type: application/json" \
      "$APIM_GW_URL/voice/admin/faults" -d "{\"$field\":$val}" | jq .
    ;;
  cosmos-throttle)
    # Fault: Cosmos DB RU throttling (429s)
    # The database is already capped at 400 RU/s (manual, no autoscale).
    # "on"  → signal the api-service to do a burst of parallel Cosmos writes to exhaust the 400 RU budget and produce 429s
    # "off" → clear the burst signal, traffic returns to normal
    : "${RG:?}"; : "${COSMOS_ACCOUNT:?}"
    if [[ "$arg" == "on" ]]; then
      echo "Enabling cosmos-throttle: setting throughput to 400 RU and signalling burst..."
      # Ensure throughput is at minimum 400 RU (should already be, but make explicit)
      az cosmosdb sql database throughput update \
        -g "$RG" --account-name "$COSMOS_ACCOUNT" --name orders \
        --throughput 400 -o none
      # Signal api-service to start parallel write bursts
      curl -fsSL -X POST -H "Ocp-Apim-Subscription-Key: $APIM_KEY" -H "Content-Type: application/json" \
        "$APIM_GW_URL/voice/admin/faults" -d '{"fault_cosmos_throttle":true}' | jq .
    else
      echo "Disabling cosmos-throttle..."
      curl -fsSL -X POST -H "Ocp-Apim-Subscription-Key: $APIM_KEY" -H "Content-Type: application/json" \
        "$APIM_GW_URL/voice/admin/faults" -d '{"fault_cosmos_throttle":false}' | jq .
    fi
    ;;
  cpu-burn)
    curl -fsSL -X POST -H "Ocp-Apim-Subscription-Key: $APIM_KEY" -H "Content-Type: application/json" \
      "$APIM_GW_URL/voice/admin/faults" -d "{\"fault_extra_cpu_burn_ms\":$arg}" | jq .
    ;;
  apim-rate-limit)
    : "${RG:?}"; : "${APIM:?}"
    if [[ "$arg" == "on" ]]; then
      az apim api policy create-or-update -g "$RG" --service-name "$APIM" --api-id voice-orders \
        --policy-content "$(cat "$(dirname "$0")/../apim/policies/fault-rate-limit-tight.xml")" --policy-format xml
    else
      az apim api policy create-or-update -g "$RG" --service-name "$APIM" --api-id voice-orders \
        --policy-content "$(cat "$(dirname "$0")/../apim/policies/inbound-correlation.xml")" --policy-format xml
    fi
    ;;
  *)
    echo "Unknown scenario: $scenario" ; exit 1 ;;
esac

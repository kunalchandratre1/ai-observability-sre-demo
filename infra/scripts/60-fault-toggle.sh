#!/usr/bin/env bash
# Toggle a fault on the running deployment.
# Usage: 60-fault-toggle.sh openai-down on|off
#        60-fault-toggle.sh speech-down on|off
#        60-fault-toggle.sh thirdparty-down on|off
#        60-fault-toggle.sh cosmos-dns-break on|off
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

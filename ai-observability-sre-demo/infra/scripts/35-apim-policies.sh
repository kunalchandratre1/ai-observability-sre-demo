#!/usr/bin/env bash
# Uploads APIM correlation + diagnostics policies. Switch fault policies via 60-fault-toggle.sh.
set -euo pipefail
: "${RG:?}"; : "${APIM:?}"
DIR="$(cd "$(dirname "$0")/../apim/policies" && pwd)"

az apim api policy create-or-update -g "$RG" --service-name "$APIM" --api-id voice-orders \
  --policy-content "$(cat "$DIR/inbound-correlation.xml")" --policy-format xml

# Apply diagnostics-log-to-eventhub at the API level
az rest --method put \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM/apis/voice-orders/diagnostics/applicationinsights?api-version=2023-09-01-preview" \
  --body @"$(dirname "$0")/diagnostic-settings.json" || true

echo "APIM policies applied."

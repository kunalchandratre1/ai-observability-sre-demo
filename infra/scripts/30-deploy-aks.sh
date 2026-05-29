#!/usr/bin/env bash
# Configures kubectl, installs nginx-ingress (internal LB), creates federated credentials,
# patches manifests with real values, applies app + OTel collector, then sets APIM backend to ingress IP.
set -euo pipefail

: "${RG:?}"
: "${AKS:?AKS cluster name}"
: "${ACR:?}"; : "${TAG:?}"
: "${UAMI:?AKS user-assigned managed identity name}"
: "${EHNS:?Event Hubs namespace name}"
: "${SPEECH_ENDPOINT:?}"
: "${OPENAI_ENDPOINT:?}"
: "${COSMOS_ENDPOINT:?}"
: "${SB_FQDN:?}"
: "${REDIS_HOST:?}"

az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
OIDC=$(az aks show -g "$RG" -n "$AKS" --query oidcIssuerProfile.issuerURL -o tsv)
UAMI_OBJ=$(az identity show -g "$RG" -n "$UAMI" --query principalId -o tsv)
UAMI_CID=$(az identity show -g "$RG" -n "$UAMI" --query clientId -o tsv)

# Federated credential for app SA
az identity federated-credential create \
  --name "fc-app-sa" --identity-name "$UAMI" -g "$RG" \
  --issuer "$OIDC" --subject "system:serviceaccount:app:app-sa" --audiences "api://AzureADTokenExchange" || true

# Internal nginx-ingress
bash "$(dirname "$0")/../../api/k8s/ingress-install.sh"
INGRESS_IP=""
for i in {1..30}; do
  INGRESS_IP=$(kubectl get svc -n ingress-basic ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || true)
  [[ -n "$INGRESS_IP" ]] && break
  sleep 5
done
echo "Internal ingress IP: $INGRESS_IP"

# OTel collector EH connection string (SendOnly SAS on aks-otel hub)
EH_CONN=$(az eventhubs eventhub authorization-rule create -g "$RG" --namespace-name "$EHNS" --eventhub-name "aks-otel" --name "otel-send" --rights Send --query primaryConnectionString -o tsv 2>/dev/null \
  || az eventhubs eventhub authorization-rule keys list -g "$RG" --namespace-name "$EHNS" --eventhub-name "aks-otel" --name "otel-send" --query primaryConnectionString -o tsv)

OUT_DIR=$(mktemp -d)
sed -e "s|REPLACE_ACR|$ACR|g" -e "s|REPLACE_TAG|$TAG|g" \
    -e "s|REPLACE_WITH_AKS_UAMI_CLIENT_ID|$UAMI_CID|g" \
    -e "s|REPLACE_SPEECH_ENDPOINT|$SPEECH_ENDPOINT|g" \
    -e "s|REPLACE_OPENAI_ENDPOINT|$OPENAI_ENDPOINT|g" \
    -e "s|REPLACE_COSMOS_ENDPOINT|$COSMOS_ENDPOINT|g" \
    -e "s|REPLACE_SB_FQDN|$SB_FQDN|g" \
    -e "s|REPLACE_REDIS_HOST|$REDIS_HOST|g" \
    "$(dirname "$0")/../../api/k8s/app.yaml" > "$OUT_DIR/app.yaml"

sed -e "s|REPLACE_EHNS|$EHNS|g" \
    -e "s|REPLACE_EH_CONNSTR|$EH_CONN|g" \
    -e "s|REPLACE_AKS_NAME|$AKS|g" \
    "$(dirname "$0")/../../api/k8s/otel-collector.yaml" > "$OUT_DIR/otel-collector.yaml"

kubectl apply -f "$OUT_DIR/otel-collector.yaml"
kubectl apply -f "$OUT_DIR/app.yaml"

# Update APIM backend to point at internal ingress
APIM=$(az apim list -g "$RG" --query "[0].name" -o tsv)
az apim api update -g "$RG" --service-name "$APIM" --api-id voice-orders \
  --service-url "http://$INGRESS_IP/api"

# Create/update the DCRA linking AKS to the Managed Prometheus DCR.
# This is the missing link that routes ama-metrics pod data to the AMW workspace.
# (Bicep creates the DCRA on fresh deploys; this handles re-runs and existing clusters.)
DCR_ID=$(az monitor data-collection rule show \
  --resource-group "$RG" --name "${PREFIX:-aiosre}-dcr-prom-${ENV:-demo}" \
  --query id -o tsv 2>/dev/null || true)
if [[ -z "$DCR_ID" ]]; then
  # Fall back to AMW-managed DCR (created automatically when AMW is provisioned)
  AMW_MANAGED_RG=$(az group list --query "[?starts_with(name,'MA_') && contains(name,'-amw-')].name" -o tsv | head -1)
  DCR_ID=$(az monitor data-collection rule list --resource-group "$AMW_MANAGED_RG" \
    --query "[0].id" -o tsv 2>/dev/null || true)
fi
if [[ -n "$DCR_ID" ]]; then
  AKS_ID=$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)
  DCRA_BODY=$(printf '{"properties":{"dataCollectionRuleId":"%s"}}' "$DCR_ID")
  az rest --method PUT \
    --url "https://management.azure.com${AKS_ID}/providers/Microsoft.Insights/dataCollectionRuleAssociations/MSProm-${AKS}?api-version=2022-06-01" \
    --body "$DCRA_BODY" --headers "Content-Type=application/json" -o none
  echo "DCRA created: ama-metrics -> AMW"
else
  echo "WARNING: DCR not found, Managed Prometheus DCRA skipped"
fi

echo "AKS deployment complete. APIM voice-orders backend -> http://$INGRESS_IP/api"

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

# kafka-bridge: HTTP→AMQP proxy that forwards OTLP/JSON from otelcol to Azure
# Event Hub using azure-eventhub SDK + Workload Identity (no SAS keys).
sed -e "s|REPLACE_WITH_AKS_UAMI_CLIENT_ID|$UAMI_CID|g" \
    -e "s|REPLACE_EHNS|$EHNS|g" \
    "$(dirname "$0")/../../api/k8s/kafka-bridge.yaml" > "$OUT_DIR/kafka-bridge.yaml"
kubectl apply -f "$OUT_DIR/kafka-bridge.yaml"

# Update APIM backend to point at internal ingress
APIM=$(az apim list -g "$RG" --query "[0].name" -o tsv)
az apim api update -g "$RG" --service-name "$APIM" --api-id voice-orders \
  --service-url "http://$INGRESS_IP/api"

# Enable Container Insights (omsagent addon) so AKS platform metrics/logs flow to LAW.
# This powers SRE Agent queries on ContainerLog, KubePodInventory, KubeNodeInventory, KubeEvents.
LA_ID=$(az monitor log-analytics workspace show -g "$RG" -n "${PREFIX:-aiosre}-la-${ENV:-demo}" --query id -o tsv 2>/dev/null || true)
if [[ -n "$LA_ID" ]]; then
  az aks enable-addons -g "$RG" -n "$AKS" \
    --addons monitoring \
    --workspace-resource-id "$LA_ID" \
    --output none
  echo "Container Insights enabled: aks -> $LA_ID"
else
  echo "WARNING: LAW ${PREFIX:-aiosre}-la-${ENV:-demo} not found — Container Insights skipped"
fi

echo "AKS deployment complete. APIM voice-orders backend -> http://$INGRESS_IP/api"

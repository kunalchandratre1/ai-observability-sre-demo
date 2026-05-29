#!/usr/bin/env bash
# Builds api-service and worker-service images, pushes to ACR.
#
# Required env:
#   RG   - resource group (default: ai-obs-sre-demo)
#   ACR  - ACR login server  e.g. aiosreacrdemo4lrdqw4e2yr2s.azurecr.io
#          (resolved automatically from RG when omitted)
#
# Optional env:
#   TAG          - image tag (default: UTC timestamp)
#   USE_ACR_TASKS=1  - build in Azure via `az acr build` (no local Docker needed)
set -euo pipefail

: "${RG:=ai-obs-sre-demo}"

# ── Resolve ACR login server ──────────────────────────────────────────────────
if [[ -z "${ACR:-}" ]]; then
  ACR_NAME=$(az acr list -g "$RG" --query "[0].name" -o tsv)
  [[ -z "$ACR_NAME" ]] && { echo "ERROR: no ACR in RG '$RG'. Export ACR=<login-server>."; exit 1; }
  ACR="${ACR_NAME}.azurecr.io"
fi
ACR_SHORT="${ACR%%.*}"

TAG=${TAG:-$(date +%Y%m%d%H%M%S)}
echo "[info] ACR=$ACR  TAG=$TAG"

ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
API_DIR="$ROOT/api/api-service"
WORKER_DIR="$ROOT/api/worker-service"

# ── Build & push ──────────────────────────────────────────────────────────────
if [[ "${USE_ACR_TASKS:-0}" == "1" ]]; then
  # ACR Tasks — build runs in Azure, no local Docker required
  echo "=== [1/2] ACR Tasks: api-service ==="
  az acr build --registry "$ACR_SHORT" -g "$RG" \
    --image "api-service:$TAG" --image "api-service:latest" "$API_DIR"

  echo "=== [2/2] ACR Tasks: worker-service ==="
  az acr build --registry "$ACR_SHORT" -g "$RG" \
    --image "worker-service:$TAG" --image "worker-service:latest" "$WORKER_DIR"
else
  # Local Docker build + push
  az acr login --name "$ACR_SHORT"

  echo "=== [1/4] Building api-service ==="
  docker build -t "$ACR/api-service:$TAG" -t "$ACR/api-service:latest" "$API_DIR"

  echo "=== [2/4] Building worker-service ==="
  docker build -t "$ACR/worker-service:$TAG" -t "$ACR/worker-service:latest" "$WORKER_DIR"

  echo "=== [3/4] Pushing api-service ==="
  docker push "$ACR/api-service:$TAG"
  docker push "$ACR/api-service:latest"

  echo "=== [4/4] Pushing worker-service ==="
  docker push "$ACR/worker-service:$TAG"
  docker push "$ACR/worker-service:latest"
fi

echo ""
echo "Build/push complete."
echo "  ACR         : $ACR"
echo "  TAG         : $TAG"
echo "  api-service : $ACR/api-service:$TAG"
echo "  worker      : $ACR/worker-service:$TAG"
echo ""
echo "Next step  ->  RG=$RG ACR=$ACR TAG=$TAG bash 30-deploy-aks.sh"

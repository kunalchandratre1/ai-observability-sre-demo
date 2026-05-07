#!/usr/bin/env bash
# Builds api/worker images, pushes to ACR. Tag = $(git rev-parse --short HEAD) when in a repo, else timestamp.
set -euo pipefail
: "${RG:=ai-obs-sre-demo}"
: "${ACR:?Set ACR (login server, e.g. aiosreacrxxx.azurecr.io)}"

TAG=${TAG:-$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}
echo "Tag: $TAG"

az acr login --name "${ACR%%.*}"

ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
docker build -t "$ACR/api-service:$TAG" -t "$ACR/api-service:latest"   "$ROOT/api/api-service"
docker build -t "$ACR/worker-service:$TAG" -t "$ACR/worker-service:latest" "$ROOT/api/worker-service"

docker push "$ACR/api-service:$TAG"
docker push "$ACR/api-service:latest"
docker push "$ACR/worker-service:$TAG"
docker push "$ACR/worker-service:latest"

echo "Build/push complete. TAG=$TAG"

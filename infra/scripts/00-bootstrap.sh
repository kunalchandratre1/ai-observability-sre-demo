#!/usr/bin/env bash
# 00-bootstrap.sh — sets up subscription/RG and exports env for downstream scripts.
set -euo pipefail
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${RG:=ai-obs-sre-demo}"
: "${LOCATION:=australiaeast}"

az account set --subscription "$SUBSCRIPTION_ID"
az group create -n "$RG" -l "$LOCATION" -o none
az config set defaults.group="$RG" defaults.location="$LOCATION"

echo "Bootstrap complete. RG=$RG LOCATION=$LOCATION"

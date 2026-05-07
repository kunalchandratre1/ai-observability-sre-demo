#!/usr/bin/env bash
# Provisions the entire demo via Bicep.
set -euo pipefail
: "${RG:=ai-obs-sre-demo}"
PARAMS_FILE="${PARAMS_FILE:-$(dirname "$0")/../bicep/main.parameters.example.json}"

DEPLOYER_OBJ_ID=$(az ad signed-in-user show --query id -o tsv)

az deployment group create \
  --resource-group "$RG" \
  --template-file "$(dirname "$0")/../bicep/main.bicep" \
  --parameters @"$PARAMS_FILE" \
  --parameters deployerObjectId="$DEPLOYER_OBJ_ID" \
  --name "main-$(date +%s)" \
  --query properties.outputs

echo "Bicep deployment complete."

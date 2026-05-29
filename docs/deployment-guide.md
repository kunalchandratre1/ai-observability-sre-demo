# AI Observability SRE Demo — Full Deployment Guide

This guide covers everything needed to deploy the demo from scratch on a new Azure subscription, or to rebuild it after a teardown.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture Overview](#2-architecture-overview)
3. [Step 0 — Clone & Configure](#3-step-0--clone--configure)
4. [Step 1 — Bootstrap RG](#4-step-1--bootstrap-rg)
5. [Step 2 — Deploy Azure Infrastructure (Bicep)](#5-step-2--deploy-azure-infrastructure-bicep)
6. [Step 3 — Bootstrap ADX Schema](#6-step-3--bootstrap-adx-schema)
7. [Step 4 — Build & Push Container Images](#7-step-4--build--push-container-images)
8. [Step 5 — Deploy AKS Workloads](#8-step-5--deploy-aks-workloads)
9. [Step 6 — Import APIM APIs & Policies](#9-step-6--import-apim-apis--policies)
10. [Step 7 — Import Grafana Dashboards](#10-step-7--import-grafana-dashboards)
11. [Step 8 — Configure SRE Agent](#11-step-8--configure-sre-agent)
12. [Fault Injection](#12-fault-injection)
13. [Teardown & Rebuild Notes](#13-teardown--rebuild-notes)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Prerequisites

| Tool | Min version | Install |
|---|---|---|
| Azure CLI | 2.60+ | `winget install -e --id Microsoft.AzureCLI` |
| Bicep CLI | 0.43+ | `az bicep install` |
| kubectl | 1.29+ | `az aks install-cli` |
| Helm | 3.14+ | `winget install -e --id Helm.Helm` |
| Docker Desktop | any | https://docs.docker.com/desktop (optional — can use ACR Tasks instead) |
| PowerShell | 7+ | `winget install -e --id Microsoft.PowerShell` |
| curl + jq | any | included in WSL / Git Bash |

Azure permissions required on the target subscription:
- **Owner** or **Contributor + User Access Administrator**

---

## 2. Architecture Overview

```
Internet
  │
  ▼
Azure APIM (External, Developer SKU)
  │  VNet-injected, NSG port 3443/443/6390
  ▼
AKS internal nginx-ingress (10.40.x.x internal IP)
  ├── api-service  (FastAPI, port 8000)
  └── worker-service (Service Bus consumer)
        │
        ├── Cosmos DB (private endpoint)
        ├── Azure Service Bus
        ├── Azure Cache for Redis
        ├── Azure OpenAI  (gpt-4o-mini)
        └── Azure Speech  (S0)

Observability pipeline:
  AKS → OTel collector → Event Hub (aks-otel)  → ADX (AppLogs / AppSpans)
  APIM diagnostics     → Event Hub (apim-diag) → ADX (APIMGatewayLogs)
  AKS → Azure Monitor (Managed Prometheus) → Grafana
  All PaaS → Log Analytics workspace

Azure Managed Grafana → 5 dashboards (golden signals, APIM, AI deps, Cosmos PE, 3rd-party)
Azure SRE Agent → ADX connector + Kusto tools + GitHub repo
On-prem VM (peered VNet) → Azure Monitor Linux Agent
```

Key resource names (suffix `4lrdqw4e2yr2s` comes from the unique string at deploy time):

| Resource | Name |
|---|---|
| Resource Group | `ai-obs-sre-demo` |
| AKS | `aiosre-aks-demo` |
| APIM | `aiosre-apim-demo` |
| ACR | `aiosreacrdemo4lrdqw4e2yr2s` |
| ADX cluster | `aiosreadxdemo4lrdqw` |
| ADX database | `observability` |
| Event Hubs NS | `aiosre-ehns-demo-4lrdqw4e2yr2s` |
| Grafana | `aiosre-grafana-demo` |
| Key Vault | `aiosrekvdemo4lrdqw4e2yr2` |
| Cosmos DB | `aiosrecosmosdemo4lrdqw4e2yr2s` |

---

## 3. Step 0 — Clone & Configure

```powershell
git clone https://github.com/kunalchandratre1/ai-observability-sre-demo.git
cd ai-observability-sre-demo

# Login
az login
az account set --subscription 'ba43c91f-2d76-4000-a7ad-24750cab54c3'

# Get your deployer object ID — used for Key Vault admin role
az ad signed-in-user show --query id -o tsv
```

Copy the parameters file and fill in your values:

```powershell
Copy-Item infra/bicep/main.parameters.example.json infra/bicep/main.parameters.json
```

Edit `infra/bicep/main.parameters.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "prefix":             { "value": "aiosre" },
    "env":                { "value": "demo" },
    "location":           { "value": "eastus2" },
    "deployerObjectId":   { "value": "<output of az ad signed-in-user show --query id>" },
    "aksNodeCount":       { "value": 2 },
    "aksNodeSku":         { "value": "Standard_D2s_v3" },
    "apimSku":            { "value": "Developer" },
    "apimPublisherEmail": { "value": "sre-demo@example.com" },
    "apimPublisherName":  { "value": "SRE Demo" },
    "adxSku":             { "value": "Dev(No SLA)_Standard_D11_v2" },
    "adxCapacity":        { "value": 1 },
    "vpnGatewayEnabled":  { "value": false },
    "onPremVmEnabled":    { "value": true },
    "onPremVmPassword":   { "value": "<strong-password-min-12-chars>" }
  }
}
```

---

## 4. Step 1 — Bootstrap RG

Creates the resource group and sets CLI defaults.

```powershell
# PowerShell (Windows)
$rg = 'ai-obs-sre-demo'
$location = 'eastus2'
az group create -n $rg -l $location
az config set defaults.group=$rg defaults.location=$location
Write-Host "RG ready: $rg"
```

Or use the bash script:
```bash
export SUBSCRIPTION_ID='ba43c91f-2d76-4000-a7ad-24750cab54c3'
export RG='ai-obs-sre-demo'
export LOCATION='eastus2'
bash infra/scripts/00-bootstrap.sh
```

---

## 5. Step 2 — Deploy Azure Infrastructure (Bicep)

### Important: Lab Subscription Auto-shutdown

If you are in a managed lab subscription (MngEnv), AKS and ADX clusters are stopped by policy on a schedule. Before each deploy run, check and start them:

```powershell
$rg = 'ai-obs-sre-demo'
$sub = 'ba43c91f-2d76-4000-a7ad-24750cab54c3'

# Check AKS
az aks show -g $rg -n 'aiosre-aks-demo' --query "{power:powerState.code, prov:provisioningState}" -o jsonc

# Start AKS if stopped
az aks start -g $rg -n 'aiosre-aks-demo'
# Wait for Running — takes 2-3 min; check with:
az aks show -g $rg -n 'aiosre-aks-demo' --query "powerState.code" -o tsv

# Check ADX
az rest --method GET `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Kusto/clusters/aiosreadxdemo4lrdqw?api-version=2023-08-15" `
  --query "properties.state" -o tsv

# Start ADX if stopped
az rest --method POST `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Kusto/clusters/aiosreadxdemo4lrdqw/start?api-version=2023-08-15"
```

### Deploy Bicep

```powershell
$rg = 'ai-obs-sre-demo'
$suffix = "r$(Get-Date -Format MMddHHmm)"   # unique suffix per run, max 8 chars
$name = "main-$(Get-Date -Format yyyyMMddHHmmss)"

az deployment group create `
  --resource-group $rg `
  --name $name `
  --template-file 'infra/bicep/main.bicep' `
  --parameters 'infra/bicep/main.parameters.json' `
  --parameters location='eastus2' `
               deployerObjectId='<your-object-id>' `
               aksNodeSku='Standard_D2s_v3' `
               adxSku='Dev(No SLA)_Standard_D11_v2' `
               adxCapacity=1 `
               deploymentSuffix=$suffix `
               onPremVmPassword='<password>'
```

> **`deploymentSuffix`** must be unique per run (max 8 chars). ARM blocks re-use of child deployment names until they expire (7 days). Use a short timestamp like `r0513` or `r1`.

Or use the bash script (from WSL/Git Bash):
```bash
export RG='ai-obs-sre-demo'
bash infra/scripts/10-deploy-bicep.sh
```

### Check deployment status

```powershell
# Overall
az deployment group show -g $rg -n $name --query "properties.provisioningState" -o tsv

# Failed operations
az deployment operation group list -g $rg -n $name `
  --query "[?properties.provisioningState=='Failed'].{name:properties.targetResource.resourceName, code:properties.statusMessage.error.code, msg:properties.statusMessage.error.message}" `
  -o jsonc
```

### Known deployment pitfalls

| Error | Cause | Fix |
|---|---|---|
| `OperationNotAllowed` on AKS | Cluster was stopped; start still in progress | Wait for `az aks show --query "powerState.code"` = `Running` AND `provisioningState` = `Succeeded` before deploying |
| `BadRequest` on ADX database | ADX cluster is stopped | Start cluster; wait for `state=Running` |
| `DeploymentActive` | Child deployment name reused | Change `deploymentSuffix` |
| `VaultAlreadyExists` | Soft-deleted KV with same name | `az keyvault purge -n <name> -l eastus2` |
| `CustomDomainInUse` | Soft-deleted Speech or OpenAI account | `az cognitiveservices account purge -g <rg> -n <name> -l eastus2` |
| `NetworkSecurityGroupNotFound` | APIM subnet NSG missing | Fixed in `network.bicep` — NSG `aiosre-nsg-apim-demo` is now provisioned automatically |
| ADX `Standard_E2a_v4` capacity error | Dev SKU requires capacity=1 | Use `Dev(No SLA)_Standard_D11_v2` with `adxCapacity=1` |
| VM disk type change blocked | Existing VM disk type differs from Bicep | Delete VM + disk first: `az vm delete -g $rg -n aiosre-onprem-vm --yes --force-deletion yes` |

---

## 6. Step 3 — Bootstrap ADX Schema

Creates tables, functions and Event Hub data connections in the `observability` database.

```bash
# bash (WSL / Git Bash)
export RG='ai-obs-sre-demo'
export ADX_CLUSTER='aiosreadxdemo4lrdqw'
export ADX_DB='observability'
export EHNS='aiosre-ehns-demo-4lrdqw4e2yr2s'
export AKS_OTEL_HUB='aks-otel'
export APIM_DIAG_HUB='apim-diag'
bash infra/scripts/15-bootstrap-adx.sh
```

**What it does:**
1. Applies `infra/adx/schema.kql` (tables: `AppLogs`, `AppSpans`, `APIMGatewayLogs` + mappings)
2. Creates data connection `aks-otel-logs` → Event Hub `aks-otel` → table `AppLogs`
3. Creates data connection `aks-otel-spans` → Event Hub `aks-otel` → table `AppSpans`
4. Creates data connection `apim-diag` → Event Hub `apim-diag` → table `APIMGatewayLogs`

---

## 7. Step 4 — Build & Push Container Images

Builds `api-service` and `worker-service` Docker images and pushes them to ACR.

### Option A — ACR Tasks (recommended, no local Docker required)

```powershell
# Windows PowerShell
cd ai-observability-sre-demo
.\infra\scripts\20-build-and-push.ps1 -UseAcrTasks -ResourceGroup 'ai-obs-sre-demo'
```

```bash
# bash (WSL / Git Bash)
export RG='ai-obs-sre-demo'
export USE_ACR_TASKS=1
bash infra/scripts/20-build-and-push.sh
```

### Option B — Local Docker build + push

```powershell
# Windows PowerShell (Docker Desktop must be running)
.\infra\scripts\20-build-and-push.ps1 -ResourceGroup 'ai-obs-sre-demo'
```

```bash
# bash
export RG='ai-obs-sre-demo'
export ACR='aiosreacrdemo4lrdqw4e2yr2s.azurecr.io'
bash infra/scripts/20-build-and-push.sh
```

The script outputs the `TAG` (UTC timestamp). Note it for the next step.

**Images pushed:**
- `<acr>/api-service:<TAG>` + `latest`
- `<acr>/worker-service:<TAG>` + `latest`

---

## 8. Step 5 — Deploy AKS Workloads

Configures kubectl, creates a workload identity federated credential, installs nginx-ingress (internal ILB), applies OTel collector + app manifests, and wires the APIM backend.

```powershell
# Windows PowerShell — auto-resolves all Azure values
.\infra\scripts\30-deploy-aks.ps1 -Tag '20260512190648'
```

```bash
# bash (WSL / Git Bash) — set all required env vars first
export RG='ai-obs-sre-demo'
export AKS='aiosre-aks-demo'
export ACR='aiosreacrdemo4lrdqw4e2yr2s.azurecr.io'
export TAG='20260512190648'
export UAMI='aiosre-aks-uami-demo'
export EHNS='aiosre-ehns-demo-4lrdqw4e2yr2s'
export SPEECH_ENDPOINT='https://eastus2.api.cognitive.microsoft.com/'
export OPENAI_ENDPOINT='https://aiosre-openai-demo.openai.azure.com/'
export COSMOS_ENDPOINT='https://aiosrecosmosdemo4lrdqw4e2yr2s.documents.azure.com:443/'
export SB_FQDN='aiosre-sb-demo-4lrdqw4e2yr2s.servicebus.windows.net'
export REDIS_HOST='aiosre-redis-demo-4lrdqw4e2yr2s.redis.cache.windows.net'
bash infra/scripts/30-deploy-aks.sh
```

**What it does:**
1. Installs kubectl + helm if missing
2. Gets AKS credentials and OIDC issuer URL
3. Creates federated credential `fc-app-sa` (workload identity binding)
4. Installs `ingress-nginx` with internal Azure Load Balancer annotation
5. Waits for the internal ingress IP to be assigned
6. Creates a `SendOnly` SAS key on the `aks-otel` Event Hub
7. Patches `api/k8s/app.yaml` and `api/k8s/otel-collector.yaml` with real values
8. Applies both manifests to the cluster
9. Updates the APIM `voice-orders` API backend to `http://<ingress-ip>/api`

**Verify:**
```powershell
kubectl get pods -n app
kubectl get pods -n observability
kubectl get svc  -n ingress-basic
```

---

## 9. Step 6 — Import APIM APIs & Policies

Applies inbound correlation policy and diagnostic settings to the `voice-orders` API.

```bash
# bash
export RG='ai-obs-sre-demo'
export APIM='aiosre-apim-demo'
bash infra/scripts/35-apim-policies.sh
```

**What it does:**
1. Uploads `infra/apim/policies/inbound-correlation.xml` to `voice-orders` API (adds `x-correlation-id`, `x-request-id`, `tracestate` headers)
2. Applies `infra/scripts/diagnostic-settings.json` to enable Application Insights / Event Hub diagnostic logging at the API level

**Verify:**
```bash
# Test the APIM gateway
curl -H "Ocp-Apim-Subscription-Key: <key>" \
     https://aiosre-apim-demo.azure-api.net/voice/health
```

---

## 10. Step 7 — Import Grafana Dashboards

Configures three data sources (ADX, Azure Monitor, Prometheus-AMW) and imports five dashboards.

```bash
# bash
export RG='ai-obs-sre-demo'
export GRAFANA='aiosre-grafana-demo'
export ADX_URI='https://aiosreadxdemo4lrdqw.eastus2.kusto.windows.net'
export ADX_DB='observability'
export AMW='aiosre-amw-demo'
export SUB='ba43c91f-2d76-4000-a7ad-24750cab54c3'
bash infra/scripts/40-import-grafana.sh
```

**Dashboards imported:**

| File | Dashboard |
|---|---|
| `d1-golden-signals.json` | API Golden Signals (latency, traffic, errors, saturation) |
| `d2-apim-health.json` | APIM Health & Rate Limits |
| `d3-ai-deps.json` | AI Dependencies (OpenAI, Speech) |
| `d4-cosmos-pe.json` | Cosmos DB + Private Endpoint |
| `d5-thirdparty.json` | 3rd-party API Availability |

**Grafana URL:**
```powershell
az grafana show -g 'ai-obs-sre-demo' -n 'aiosre-grafana-demo' --query properties.endpoint -o tsv
```

---

## 11. Step 8 — Configure SRE Agent

The SRE Agent (preview) is partially portal-driven. Run the bootstrap script then complete portal steps:

```bash
# bash
export RG='ai-obs-sre-demo'
export LOCATION='eastus2'
export ADX_CLUSTER_URI='https://aiosreadxdemo4lrdqw.eastus2.kusto.windows.net'
export ADX_DB='observability'
export SRE_UAMI='aiosre-sre-uami-demo'
bash infra/scripts/50-create-sre-agent.sh
```

**Manual portal steps** (see also `docs/runbooks/sre-agent-setup.md`):
1. Open the SRE Agent in the Azure Portal
2. Add **ADX connector** → select cluster `aiosreadxdemo4lrdqw` / database `observability`
3. Connect **GitHub repo**: `https://github.com/kunalchandratre1/ai-observability-sre-demo`
4. Upload Kusto tools from `infra/sre-agent/kusto-tools/*.kql`

---

## 12. Fault Injection

Use `60-fault-toggle.sh` to inject and clear faults for demo scenarios:

```bash
export APIM_GW_URL='https://aiosre-apim-demo.azure-api.net'
export APIM_KEY='<voice-orders-subscription-key>'

# Fault scenarios
bash infra/scripts/60-fault-toggle.sh openai-down on
bash infra/scripts/60-fault-toggle.sh speech-down on
bash infra/scripts/60-fault-toggle.sh thirdparty-down on
bash infra/scripts/60-fault-toggle.sh cosmos-dns-break on
bash infra/scripts/60-fault-toggle.sh apim-rate-limit on     # tightens rate limit to 2 req/min
bash infra/scripts/60-fault-toggle.sh cpu-burn 500           # 500ms extra CPU per request
bash infra/scripts/60-fault-toggle.sh exception on

# Restore normal
bash infra/scripts/60-fault-toggle.sh openai-down off
bash infra/scripts/60-fault-toggle.sh apim-rate-limit off    # restores inbound-correlation policy
```

Runbooks for each scenario are in `docs/runbooks/`:
- `01-backend-api-fault.md`
- `02-apim-rate-limit.md`
- `03-cosmos-private-endpoint.md`
- `04-openai-down.md`
- `05-speech-down.md`
- `06-thirdparty-down.md`
- `07-cpu-saturation.md`
- `08-bad-deployment.md`

---

## 13. Teardown & Rebuild Notes

### Full teardown

```powershell
az group delete -n 'ai-obs-sre-demo' --yes --no-wait
```

### Soft-delete purges (required before redeploy)

After teardown, some resources go into soft-delete and will block a fresh deploy with the same names:

```powershell
$location = 'eastus2'

# Key Vault
az keyvault list-deleted --query "[].name" -o tsv | ForEach-Object {
    az keyvault purge -n $_ -l $location
}

# Cognitive Services (Speech + OpenAI)
az cognitiveservices account list-deleted --query "[].name" -o tsv 2>$null | ForEach-Object {
    az cognitiveservices account purge -g 'ai-obs-sre-demo' -n $_ -l $location 2>$null
}
```

### Rebuild sequence

```
1. Soft-delete purge (above)
2. az group create
3. Step 2  — Bicep deploy   (new deploymentSuffix)
4. Step 3  — ADX schema
5. Step 4  — Build & push   (new TAG)
6. Step 5  — AKS workloads  (same TAG)
7. Step 6  — APIM policies
8. Step 7  — Grafana dashboards
9. Step 8  — SRE Agent
```

### Lab subscription (auto-shutdown) — pre-deploy checklist

Run before every Bicep deploy in a managed lab environment:

```powershell
$rg  = 'ai-obs-sre-demo'
$sub = 'ba43c91f-2d76-4000-a7ad-24750cab54c3'

# 1. AKS
$aksState = az aks show -g $rg -n 'aiosre-aks-demo' --query "powerState.code" -o tsv 2>$null
if ($aksState -ne 'Running') {
    az aks start -g $rg -n 'aiosre-aks-demo'
    Write-Host "Waiting for AKS..."
    do { Start-Sleep 20; $aksState = az aks show -g $rg -n 'aiosre-aks-demo' --query "powerState.code" -o tsv } while ($aksState -ne 'Running')
}
Write-Host "AKS: $aksState"

# 2. ADX
$adxState = az rest --method GET `
    --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Kusto/clusters/aiosreadxdemo4lrdqw?api-version=2023-08-15" `
    --query "properties.state" -o tsv 2>$null
if ($adxState -ne 'Running') {
    az rest --method POST `
        --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Kusto/clusters/aiosreadxdemo4lrdqw/start?api-version=2023-08-15"
    Write-Host "Waiting for ADX..."
    do { Start-Sleep 30; $adxState = az rest --method GET --url "..." --query "properties.state" -o tsv } while ($adxState -ne 'Running')
}
Write-Host "ADX: $adxState"

Write-Host "Pre-deploy checks passed. Ready to deploy."
```

---

## 14. Troubleshooting

### Check all resource states

```powershell
az resource list -g 'ai-obs-sre-demo' `
    --query "sort_by([].{type:type, name:name}, &type)" -o table
```

### Check last 5 deployment operations

```powershell
$rg = 'ai-obs-sre-demo'
az deployment group list -g $rg `
    --query "sort_by([],&properties.timestamp)[-5:].{name:name, state:properties.provisioningState, time:properties.timestamp}" `
    -o table
```

### Check pod logs

```powershell
az aks get-credentials -g 'ai-obs-sre-demo' -n 'aiosre-aks-demo' --overwrite-existing
kubectl logs -n app -l app=api-service    --tail=50
kubectl logs -n app -l app=worker-service --tail=50
kubectl logs -n observability -l app=otel-collector --tail=50
```

### APIM gateway test

```bash
curl -i -H "Ocp-Apim-Subscription-Key: <key>" \
  https://aiosre-apim-demo.azure-api.net/voice/health
```

### ADX query connectivity test

```kql
// Run in ADX Web UI: https://dataexplorer.azure.com
// Cluster: https://aiosreadxdemo4lrdqw.eastus2.kusto.windows.net
// Database: observability
AppLogs | take 5
APIMGatewayLogs | take 5
AppSpans | take 5
```

### Grafana data source test

Open Grafana → Configuration → Data Sources → Test each source (ADX, AzureMonitor, Prometheus-AMW).

---

*Last updated: May 2026 — deployment run r10, images tag `20260512190648`*

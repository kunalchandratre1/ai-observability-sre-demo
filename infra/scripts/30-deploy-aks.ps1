<#
.SYNOPSIS
    Deploys the AKS application workload: nginx-ingress, OTel collector, api-service, worker-service.
    Then wires the APIM backend URL to the internal ingress IP.

.PARAMETER ResourceGroup
    Azure resource group (default: ai-obs-sre-demo)

.PARAMETER Tag
    Container image tag to deploy (default: latest)

.EXAMPLE
    .\30-deploy-aks.ps1 -Tag 20260512190648
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ai-obs-sre-demo',
    [string] $Tag           = 'latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the script directory early — used in [5/8] for helm values and [7/8] for K8s manifests.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== [0/8] Resolving Azure resource values ==="

$rg = $ResourceGroup

# Use ConvertFrom-Json throughout to avoid JMESPath pipe characters (|) which
# PowerShell misinterprets as pipeline operators when calling az.cmd on Windows.

$AKS       = (az aks list -g $rg -o json | ConvertFrom-Json)[0].name
$acrShort  = (az acr list -g $rg -o json | ConvertFrom-Json)[0].name
$ACR       = "$acrShort.azurecr.io"
$UAMI      = (az identity list -g $rg -o json | ConvertFrom-Json |
                 Where-Object { $_.name -like '*aks-uami*' } |
                 Select-Object -First 1).name
$UAMI_CID  = az identity show -g $rg -n $UAMI --query clientId -o tsv
$EHNS      = (az eventhubs namespace list -g $rg -o json | ConvertFrom-Json)[0].name

$cogAccounts      = az cognitiveservices account list -g $rg -o json | ConvertFrom-Json
$speechAccount    = $cogAccounts | Where-Object kind -eq 'SpeechServices' | Select-Object -First 1
$speechName       = $speechAccount.name
$SPEECH_REGION    = $speechAccount.location   # e.g. australiaeast
# For AAD token auth, Speech TTS requires the custom-domain endpoint + /tts path.
# The raw endpoint from Azure is https://<name>.cognitiveservices.azure.com/ — append /tts (strip trailing slash first).
$speechRawEndpoint = az cognitiveservices account show -g $rg -n $speechName --query properties.endpoint -o tsv
$SPEECH_ENDPOINT  = ($speechRawEndpoint.TrimEnd('/')) + '/tts'
$openaiName       = ($cogAccounts | Where-Object kind -eq 'OpenAI' | Select-Object -First 1).name
$OPENAI_ENDPOINT  = az cognitiveservices account show -g $rg -n $openaiName --query properties.endpoint -o tsv

$cosmosName      = (az cosmosdb list -g $rg -o json | ConvertFrom-Json)[0].name
$COSMOS_ENDPOINT = az cosmosdb show -g $rg -n $cosmosName --query documentEndpoint -o tsv
$sbName          = (az servicebus namespace list -g $rg -o json | ConvertFrom-Json)[0].name
$SB_FQDN         = "$sbName.servicebus.windows.net"
$redisName       = (az redis list -g $rg -o json | ConvertFrom-Json)[0].name
$REDIS_HOST      = az redis show -g $rg -n $redisName --query hostName -o tsv
$APIM            = (az apim list -g $rg -o json | ConvertFrom-Json)[0].name

Write-Host "  AKS      : $AKS"
Write-Host "  ACR      : $ACR  Tag: $Tag"
Write-Host "  UAMI CID : $UAMI_CID"
Write-Host "  EHNS     : $EHNS"
Write-Host "  Cosmos   : $COSMOS_ENDPOINT"
Write-Host "  Redis    : $REDIS_HOST"
Write-Host "  SB FQDN  : $SB_FQDN"
Write-Host "  APIM     : $APIM"
Write-Host "  Speech   : $SPEECH_ENDPOINT (region: $SPEECH_REGION)"

# ── Ensure kubelet identity has AcrPull on ACR ────────────────────────────────
# The kubelet (node-pool) identity is auto-created by AKS and is separate from
# the workload UAMI. It must have AcrPull to pull images; missing this causes
# 401 ImagePullBackOff on every pod. This step is idempotent.
Write-Host ""
Write-Host "=== [0b/8] Ensuring AKS kubelet identity has AcrPull on ACR ==="
$kubeletPrincipalId = az aks show -g $rg -n $AKS --query identityProfile.kubeletidentity.objectId -o tsv
$acrId = az acr show -g $rg -n $acrShort --query id -o tsv
$existingAcrPull = az role assignment list --assignee $kubeletPrincipalId --scope $acrId `
    --query "[?roleDefinitionName=='AcrPull'].id" -o tsv 2>$null
if ($existingAcrPull) {
    Write-Host "  AcrPull already assigned to kubelet identity — skipping."
} else {
    Write-Host "  Assigning AcrPull to kubelet identity $kubeletPrincipalId ..."
    az role assignment create `
        --role '7f951dda-4ed3-4680-a7ca-43fe172d538d' `
        --assignee $kubeletPrincipalId `
        --scope $acrId `
        --query "roleDefinitionName" -o tsv
    Write-Host "  AcrPull assigned. Waiting 15s for propagation..."
    Start-Sleep 15
}

# ── Install kubectl + kubelogin if missing ─────────────────────────────────────
Write-Host ""
Write-Host "=== [1/8] Ensuring kubectl + kubelogin ==="

# az aks install-cli puts binaries here on Windows
$azKubectlDir   = Join-Path $env:USERPROFILE '.azure-kubectl'
$azKubeloginDir = Join-Path $env:USERPROFILE '.azure-kubelogin'

# Add known az-installed locations to PATH for this session now (before checking)
foreach ($d in @($azKubectlDir, $azKubeloginDir)) {
    if ((Test-Path $d) -and ($env:PATH -notlike "*$d*")) {
        $env:PATH = "$d;$env:PATH"
    }
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    Write-Host "kubectl not found — installing via az aks install-cli (downloading binaries, ~30s) ..."
    az aks install-cli
    # Add the newly installed directories to PATH
    foreach ($d in @($azKubectlDir, $azKubeloginDir)) {
        if ((Test-Path $d) -and ($env:PATH -notlike "*$d*")) {
            $env:PATH = "$d;$env:PATH"
        }
    }
}
kubectl version --client 2>&1 | Select-Object -First 1

# ── Install helm if missing ────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [2/8] Ensuring helm ==="
$helm = Get-Command helm -ErrorAction SilentlyContinue
if (-not $helm) {
    Write-Host "helm not found — installing via winget ..."
    winget install -e --id Helm.Helm --accept-source-agreements --accept-package-agreements 2>&1 | Select-Object -Last 5
    $env:PATH = $env:PATH + ';C:\ProgramData\chocolatey\bin;' + "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Helm.Helm_Microsoft.Winget.Source_8wekyb3d8bbwe\helm-v3*"
    $helm = Get-Command helm -ErrorAction SilentlyContinue
}
if (-not $helm) { throw "helm is required. Install from https://helm.sh/docs/intro/install/ and re-run." }
helm version --short 2>&1 | Select-Object -Last 1

# ── Kube credentials ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [3/8] Getting AKS credentials ==="
az aks get-credentials -g $rg -n $AKS --overwrite-existing
# Note: JMESPath is case-sensitive. The ARM field is 'issuerUrl' (not 'issuerURL').
$OIDC = az aks show -g $rg -n $AKS --query oidcIssuerProfile.issuerUrl -o tsv

# ── Federated credentials (always up-to-date with current OIDC issuer) ────────
# Required for workload identity: links the AKS OIDC issuer to the service
# accounts so pods can get Azure AD tokens via DefaultAzureCredential.
#
# CRITICAL on cluster delete+recreate: AKS generates a NEW OIDC issuer URL each
# time the cluster is created. A federated credential that references the OLD issuer
# URL silently stops working — DefaultAzureCredential returns 401 on every Azure
# SDK call. We therefore always compare the stored issuer against the current
# cluster issuer and DELETE + RECREATE the credential if they differ.
Write-Host ""
Write-Host "=== [4/8] Federated credentials for workload identity ==="
Write-Host "  Current OIDC issuer: $OIDC"

function Set-FederatedCredential {
    param(
        [string]$Name,
        [string]$Subject,
        [string]$Rg,
        [string]$UamiName,
        [string]$OidcIssuer
    )
    $existing = az identity federated-credential list `
        -g $Rg --identity-name $UamiName `
        --query "[?name=='$Name'].{name:name,issuer:issuer}" -o json 2>$null | ConvertFrom-Json
    if ($existing -and $existing.Count -gt 0) {
        if ($existing[0].issuer -eq $OidcIssuer) {
            Write-Host "  '$Name': issuer matches current cluster — no change."
            return
        }
        # OIDC issuer changed (cluster was recreated) — delete stale credential and recreate.
        Write-Host "  '$Name': issuer mismatch (stored=$($existing[0].issuer)) — deleting stale credential..."
        az identity federated-credential delete -g $Rg --identity-name $UamiName --name $Name --yes 2>&1 | Out-Null
    }
    Write-Host "  '$Name': creating for subject '$Subject'..."
    az identity federated-credential create `
        --name $Name --identity-name $UamiName -g $Rg `
        --issuer $OidcIssuer `
        --subject $Subject `
        --audiences 'api://AzureADTokenExchange' | Out-Null
    Write-Host "  '$Name': created." -ForegroundColor Green
}

# app-sa: used by api-service and worker-service (namespace: app)
Set-FederatedCredential -Name 'fc-app-sa' `
    -Subject 'system:serviceaccount:app:app-sa' `
    -Rg $rg -UamiName $UAMI -OidcIssuer $OIDC

# bridge-sa: used by kafka-bridge (namespace: observability)
Set-FederatedCredential -Name 'bridge-sa-federated' `
    -Subject 'system:serviceaccount:observability:bridge-sa' `
    -Rg $rg -UamiName $UAMI -OidcIssuer $OIDC

# ── nginx-ingress (internal ILB) ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== [5/8] Installing nginx-ingress (internal ILB) ==="
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update 2>&1 | Select-Object -Last 2
helm repo update 2>&1 | Select-Object -Last 2

# All service configuration (ILB IP, externalTrafficPolicy, healthCheckNodePort,
# nodePorts, annotations) lives in nginx-ilb-values.yaml and is applied via
# --values on every helm install/upgrade. Helm owns the service entirely —
# no separate kubectl apply is needed or safe (would cause SSA field-manager conflicts).
#
# ILB HEALTH PROBE: externalTrafficPolicy: Local causes kube-proxy to create a
# healthCheckNodePort (32500). kube-proxy returns HTTP 200/503 based on whether
# nginx pods are local. CCM reads healthCheckNodePort from the service spec and
# uses it as the ILB probe target — it never overrides a healthCheckNodePort probe,
# making this stable across cluster stop/start without any post-deploy REST API calls.
$NginxValuesFile = Join-Path $ScriptDir "nginx-ilb-values.yaml"
if (-not (Test-Path $NginxValuesFile)) {
    throw "nginx-ilb-values.yaml not found at $NginxValuesFile — cannot deploy nginx ingress."
}

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-basic --create-namespace `
    --values $NginxValuesFile `
    --wait --timeout 5m 2>&1 | Select-Object -Last 8

Write-Host "Waiting for ingress controller to get an internal IP (up to 5 min)..."
$INGRESS_IP = ""
for ($i = 1; $i -le 60; $i++) {
    Start-Sleep 5
    $INGRESS_IP = kubectl get svc -n ingress-basic ingress-nginx-controller `
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($INGRESS_IP) { break }
    if ($i % 6 -eq 0) { Write-Host "  ...still waiting ($($i*5)s)" }
}
if (-not $INGRESS_IP) {
    Write-Host ""
    Write-Host "ERROR: Ingress controller did not receive an IP after 5 minutes." -ForegroundColor Red
    Write-Host ""
    Write-Host "--- kubectl get svc -n ingress-basic ---"
    kubectl get svc -n ingress-basic
    Write-Host ""
    Write-Host "--- kubectl describe svc ingress-nginx-controller -n ingress-basic ---"
    kubectl describe svc ingress-nginx-controller -n ingress-basic
    Write-Host ""
    Write-Host "--- Recent events in ingress-basic namespace ---"
    kubectl get events -n ingress-basic --sort-by='.lastTimestamp' | Select-Object -Last 20
    Write-Host ""
    Write-Host "Common causes:"
    Write-Host "  1. AKS UAMI is missing 'Network Contributor' role on the resource group."
    Write-Host "     Fix: az role assignment create --role '4d97b98b-1d4f-4787-a291-c67834d212e7' --assignee <aks-uami-principalId> --scope /subscriptions/.../resourceGroups/..."
    Write-Host "  2. Subnet NSG or UDR is blocking LB provisioning."
    throw "Ingress controller did not receive an IP after 5 minutes. See diagnostics above."
}
Write-Host "  Internal ingress IP: $INGRESS_IP"

# ── RBAC: Event Hub Data Sender for kafka-bridge workload identity ────────────
# kafka-bridge uses Azure Workload Identity (DefaultAzureCredential) to authenticate
# to Event Hub via AMQP — no SAS keys required. The AKS UAMI needs the
# Azure Event Hubs Data Sender role on the namespace so the bridge can send to
# the aks-otel event hub.
Write-Host ""
Write-Host "=== [6/8] Assigning Azure Event Hubs Data Sender role to UAMI ==="
$uamiPrincipalId = az identity show -g $rg -n $UAMI --query principalId -o tsv
$ehnsId          = az eventhubs namespace show -g $rg --name $EHNS --query id -o tsv
$existingEhRole  = az role assignment list --assignee $uamiPrincipalId --scope $ehnsId `
    --query "[?roleDefinitionName=='Azure Event Hubs Data Sender'].id" -o tsv 2>$null
if ($existingEhRole) {
    Write-Host "  Azure Event Hubs Data Sender already assigned — skipping."
} else {
    az role assignment create `
        --assignee-object-id $uamiPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role 'Azure Event Hubs Data Sender' `
        --scope $ehnsId | Out-Null
    Write-Host "  Azure Event Hubs Data Sender role assigned. Waiting 15s for propagation..."
    Start-Sleep 15
}

# ── Patch manifests and apply ─────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [7/8] Patching and applying K8s manifests ==="

$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '../..')).Path
$K8sDir    = Join-Path $RepoRoot 'api/k8s'
$TmpDir    = Join-Path $env:TEMP "aks-deploy-$(Get-Date -Format yyyyMMddHHmmss)"
New-Item -ItemType Directory -Path $TmpDir | Out-Null

# Patch app.yaml
$appYaml = Get-Content "$K8sDir/app.yaml" -Raw
$appYaml = $appYaml `
    -replace 'REPLACE_ACR',                 $ACR `
    -replace 'REPLACE_TAG',                 $Tag `
    -replace 'REPLACE_WITH_AKS_UAMI_CLIENT_ID', $UAMI_CID `
    -replace 'REPLACE_SPEECH_REGION',       $SPEECH_REGION `
    -replace 'REPLACE_SPEECH_ENDPOINT',     $SPEECH_ENDPOINT `
    -replace 'REPLACE_OPENAI_ENDPOINT',     $OPENAI_ENDPOINT `
    -replace 'REPLACE_COSMOS_ENDPOINT',     $COSMOS_ENDPOINT `
    -replace 'REPLACE_SB_FQDN',             $SB_FQDN `
    -replace 'REPLACE_REDIS_HOST',          $REDIS_HOST
$appYaml | Set-Content "$TmpDir/app.yaml" -Encoding UTF8

# Patch otel-collector.yaml (only REPLACE_AKS_NAME needed; no EH secrets)
$otelYaml = Get-Content "$K8sDir/otel-collector.yaml" -Raw
$otelYaml = $otelYaml `
    -replace 'REPLACE_AKS_NAME',   $AKS
$otelYaml | Set-Content "$TmpDir/otel-collector.yaml" -Encoding UTF8

# app.yaml must be applied first — it creates the 'app' and 'observability' namespaces.
# otel-collector.yaml targets namespace 'observability' and will fail with NotFound if applied first.
kubectl apply -f "$TmpDir/app.yaml"
kubectl apply -f "$TmpDir/otel-collector.yaml"

# kafka-bridge: HTTP→AMQP proxy forwarding OTLP/JSON from otelcol to Azure Event
# Hub using azure-eventhub SDK + Workload Identity (DefaultAzureCredential).
# The bridge-sa ServiceAccount (defined in kafka-bridge.yaml) gets Azure AD tokens
# via the bridge-sa-federated federated credential created in step [4/8].
$bridgeYaml = Get-Content "$K8sDir/kafka-bridge.yaml" -Raw
$bridgeYaml = $bridgeYaml `
    -replace 'REPLACE_WITH_AKS_UAMI_CLIENT_ID', $UAMI_CID `
    -replace 'REPLACE_EHNS',                     $EHNS
$bridgeYaml | Set-Content "$TmpDir/kafka-bridge.yaml" -Encoding UTF8
kubectl apply -f "$TmpDir/kafka-bridge.yaml"

Write-Host "  Manifests applied."

# ── Wait for rollouts ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [7b/8] Waiting for pod rollouts (up to 3 min each) ==="
$rolloutOk = $true
foreach ($item in @(
    @{ ns='observability'; name='otel-collector' },
    @{ ns='observability'; name='kafka-bridge'   },
    @{ ns='app';           name='api-service'    },
    @{ ns='app';           name='worker-service' }
)) {
    Write-Host "  Waiting for $($item.name) ..."
    $status = kubectl rollout status deployment/$($item.name) -n $($item.ns) --timeout=180s 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: $($item.name) did not become ready: $status" -ForegroundColor Yellow
        $rolloutOk = $false
    } else {
        Write-Host "  $($item.name) Ready" -ForegroundColor Green
    }
}
if (-not $rolloutOk) {
    Write-Host ""
    Write-Host "One or more deployments are not ready. Checking pod status:" -ForegroundColor Yellow
    kubectl get pods -n app
    kubectl get pods -n observability
}

# ── Update APIM backend ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [8/8] Updating APIM backend to internal ingress ==="
$backendUrl = "http://$INGRESS_IP/api"
$subId = az account show --query id -o tsv

# Check if voice-orders API exists; if not, warn and skip
$apiExists = az rest --method GET `
    --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$APIM/apis/voice-orders?api-version=2023-05-01-preview" `
    --query "name" -o tsv 2>$null

if ($apiExists) {
    az apim api update -g $rg --service-name $APIM --api-id voice-orders `
        --service-url $backendUrl 2>&1 | Select-Object -Last 2
    Write-Host "  APIM voice-orders backend -> $backendUrl"
} else {
    Write-Host "  voice-orders API not yet in APIM — run 35-apim-policies.ps1 first, then update backend manually."
    Write-Host "  Backend URL to use: $backendUrl"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "AKS deployment complete."
Write-Host "  Ingress IP   : $INGRESS_IP"
Write-Host "  Backend URL  : $backendUrl"
Write-Host "  Image tag    : $Tag"
Write-Host ""
Write-Host "Check pod status:"
Write-Host "  kubectl get pods -n app"
Write-Host "  kubectl get pods -n observability"
Write-Host ""
Write-Host "Next step  ->  .\35-apim-policies.ps1"

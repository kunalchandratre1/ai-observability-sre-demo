<#
.SYNOPSIS
    Builds api-service and worker-service Docker images and pushes them to ACR.

.DESCRIPTION
    - Logs in to ACR using `az acr login`
    - Builds both service images with a timestamp tag + `latest`
    - Optionally uses ACR Tasks (az acr build) when Docker is not installed locally
    - Pushes to ACR login server

.PARAMETER ResourceGroup
    Azure resource group containing the ACR (default: ai-obs-sre-demo)

.PARAMETER AcrName
    Short ACR name without the .azurecr.io suffix.
    Resolved automatically from the RG if omitted.

.PARAMETER Tag
    Image tag. Defaults to a UTC timestamp (yyyyMMddHHmmss).

.PARAMETER UseAcrTasks
    If set, skips local Docker and uses `az acr build` (runs build in Azure).
    Useful when Docker Desktop is not available locally.

.EXAMPLE
    # Local Docker build + push
    .\20-build-and-push.ps1

.EXAMPLE
    # ACR Tasks build (no local Docker needed)
    .\20-build-and-push.ps1 -UseAcrTasks
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ai-obs-sre-demo',
    [string] $AcrName       = '',
    [string] $Tag           = (Get-Date -Format 'yyyyMMddHHmmss'),
    [switch] $UseAcrTasks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Windows encoding fix ───────────────────────────────────────────────────────
# az acr build streams Docker build logs via Python; on Windows the default
# 'charmap' codec chokes on Unicode apt-get output. Force UTF-8 for the process.
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Resolve ACR ────────────────────────────────────────────────────────────────
if (-not $AcrName) {
    Write-Host "[info] Resolving ACR name from resource group '$ResourceGroup'..."
    $AcrName = az acr list -g $ResourceGroup --query "[0].name" -o tsv 2>&1
    if (-not $AcrName) { throw "No ACR found in resource group '$ResourceGroup'. Set -AcrName explicitly." }
}
$LoginServer = "$AcrName.azurecr.io"
Write-Host "[info] ACR: $LoginServer  Tag: $Tag"

# ── Repo root (two levels up from scripts/) ────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '../..')).Path
$ApiDir    = Join-Path $RepoRoot 'api/api-service'
$WorkerDir = Join-Path $RepoRoot 'api/worker-service'

foreach ($d in @($ApiDir, $WorkerDir)) {
    if (-not (Test-Path "$d/Dockerfile")) { throw "Dockerfile not found at $d" }
}

# ── Build & push ───────────────────────────────────────────────────────────────
if ($UseAcrTasks) {
    # ---- ACR Tasks (no local Docker required) ---------------------------------
    # --no-logs avoids Windows charmap encoding errors from Docker build output.
    # Build status (Succeeded/Failed) is returned in the JSON response instead.
    Write-Host ""
    Write-Host "=== [1/2] ACR Tasks build: api-service ==="
    $result = az acr build `
        --registry $AcrName `
        --resource-group $ResourceGroup `
        --image "api-service:$Tag" `
        --image "api-service:latest" `
        --no-logs `
        $ApiDir | ConvertFrom-Json
    if ($result.provisioningState -ne 'Succeeded') { throw "api-service build failed: $($result.runErrorMessage)" }
    Write-Host "  api-service built: $($result.outputImages[0].digest)"

    Write-Host ""
    Write-Host "=== [2/2] ACR Tasks build: worker-service ==="
    $result = az acr build `
        --registry $AcrName `
        --resource-group $ResourceGroup `
        --image "worker-service:$Tag" `
        --image "worker-service:latest" `
        --no-logs `
        $WorkerDir | ConvertFrom-Json
    if ($result.provisioningState -ne 'Succeeded') { throw "worker-service build failed: $($result.runErrorMessage)" }
    Write-Host "  worker-service built: $($result.outputImages[0].digest)"

} else {
    # ---- Local Docker ---------------------------------------------------------
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        Write-Warning "Docker is not in PATH. Re-run with -UseAcrTasks to build inside Azure instead."
        exit 1
    }

    Write-Host ""
    Write-Host "=== Logging in to ACR ==="
    az acr login --name $AcrName

    Write-Host ""
    Write-Host "=== [1/4] Building api-service ==="
    docker build `
        -t "$LoginServer/api-service:$Tag" `
        -t "$LoginServer/api-service:latest" `
        $ApiDir

    Write-Host ""
    Write-Host "=== [2/4] Building worker-service ==="
    docker build `
        -t "$LoginServer/worker-service:$Tag" `
        -t "$LoginServer/worker-service:latest" `
        $WorkerDir

    Write-Host ""
    Write-Host "=== [3/4] Pushing api-service ==="
    docker push "$LoginServer/api-service:$Tag"
    docker push "$LoginServer/api-service:latest"

    Write-Host ""
    Write-Host "=== [4/4] Pushing worker-service ==="
    docker push "$LoginServer/worker-service:$Tag"
    docker push "$LoginServer/worker-service:latest"
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Build/push complete."
Write-Host "  ACR         : $LoginServer"
Write-Host "  Tag         : $Tag"
Write-Host "  api-service : $LoginServer/api-service:$Tag"
Write-Host "  worker      : $LoginServer/worker-service:$Tag"
Write-Host ""
Write-Host "Next step  ->  .\30-deploy-aks.ps1 -Tag $Tag"

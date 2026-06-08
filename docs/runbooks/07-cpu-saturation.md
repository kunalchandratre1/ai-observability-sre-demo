# Scenario 7 — AKS CPU saturation on specific pods

**Goal:** Prove SRE Agent can correlate latency increase to CPU saturation on a specific pod (cross-plane: ADX traces × Managed Prometheus metrics).

## Inject

Choose **any one** of the three methods:

**Option A — UI button (easiest)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **CPU burn 800ms** (pre-set to 800ms spin per request).

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario cpu-burn -State 800
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh cpu-burn 800   # 800ms CPU spin per request
```

Then generate sustained traffic — click **Burst x10** in the UI several times to saturate the pod.

## Symptoms
- **D1 — Golden Signals** →
  - "Latency p95 (per dependency)" rises (handler itself is slow before any dep).
  - "AKS pod CPU (Managed Prometheus)" panel shows one pod at >85% sustained.
- **HPA** scales `api-service` from 2→ up to 10 (visible in `kubectl get hpa -n app -w`).

## SRE Agent RCA
1. `QueryLatencyPercentiles(30m, "api-service")` → p95 increased ~ 800ms above baseline starting at T0.
2. Cross-reference Grafana D1 CPU panel (Agent links it; AKS metrics live in Managed Prometheus).
3. `DeploymentCorrelation(1h)` → no new deployment_version → not a code regression.
4. `TraceDrilldown(<slow trace>)` → handler span has 800ms gap before any dep span → CPU-bound, not dependency-bound.

Root cause: sustained CPU saturation on api-service pods (synthetic burn); HPA scaling helps but does not fully recover during burn.

## Remediation

**Option A — UI:** Click **Reset all** in the Fault toggles section (sets cpu-burn to 0ms).

**Option B — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
.\infra\scripts\60-fault-toggle.ps1 -Scenario cpu-burn -State 0
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh cpu-burn 0
```

Real-world fixes: bump CPU requests/limits, raise HPA targetCPU, investigate hot-path code.

## Verification
- D1 latency p95 returns to baseline.
- HPA scales back down.

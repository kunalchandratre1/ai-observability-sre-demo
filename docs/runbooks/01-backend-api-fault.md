# Scenario 1 — Backend API fault only (not APIM)

**Goal:** Show that APIM is healthy while the backend is throwing unhandled exceptions, and the SRE Agent points at the backend (not APIM) using correlation_id joins.

## Pre-state
- All Grafana dashboards green.
- `GET /voice/admin/faults` returns all `false`.

## Inject

Choose **any one** of the three methods — they all call the same admin endpoint:

**Option A — UI button (easiest, no terminal needed)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **Force exception**.

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
# Run from repo root
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario exception -State on
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh exception on
```

Then click **Burst x10** in the UI 2–3 times to generate traffic.

## Symptoms (Grafana)
- **D1 — Golden Signals** → "Errors per minute (AppExceptions)" spikes for `service=api-service`, `DependencyName=""` (synthetic exception is not dep-tagged).
- **D1 — Golden Signals** → **"Top recent exceptions"** table (bottom of the dashboard) populates with rows showing:
  - `ExceptionType = RuntimeError`
  - `ExceptionMessage = "synthetic unhandled exception (...)"`
  - `DependencyName` is empty — confirms the fault is in the main request handler, not a downstream call
  - Click **copy** next to `correlation_id` or `trace_id` on any row → paste into the dashboard filter variables to drill into that single transaction across all panels.
- **D2 — APIM Health** → APIM `Failed Requests` rises **with backend `Status=500`**, while APIM platform metrics show no APIM-internal failure.

## SRE Agent RCA
Prompt: "Why are voice orders failing in the last 15 minutes?"

Expected reasoning chain (≥ 0.9 confidence):
1. `QueryRecentAppErrors(15m, "api-service")` → `RuntimeError` dominates with no `DependencyName`.
2. `APIMvsBackendCorrelation(15m, "submit-order")` → APIM 5xx rows have `BackendStatus=500`; on join with `AppExceptions.CorrelationId` every APIM failure has a matching backend exception.
3. `TraceDrilldown(<one trace_id>)` → `POST /api/orders` span ends in error before any `dep.*` span is created.
4. `DeploymentCorrelation(15m)` → only one deployment_version, no diff → rules out bad-deploy.

Root cause: api-service raises synthetic exception (admin fault toggle).

## Remediation

**Option A — UI:** Click **Reset all** in the Fault toggles section.

**Option B — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
.\infra\scripts\60-fault-toggle.ps1 -Scenario exception -State off
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh exception off
```

**Option D — Restart api-service deployment (clears per-pod in-memory fault state):**
```powershell
kubectl rollout restart deployment/api-service -n app
kubectl rollout status deployment/api-service -n app --timeout=120s
```

Use this if `-State off` clears one pod but exceptions still continue from another replica.

## Verification
- D1 errors panel returns to baseline within 1 minute.
- APIM 5xx rate drops to 0; `Successful Requests` recovers.

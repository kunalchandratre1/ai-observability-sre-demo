# Scenario 2 — APIM-only fault (rate limit)

**Goal:** APIM blocks calls with 429s; backend stays idle and healthy. SRE Agent must conclude APIM is the cause, not the backend.

## Inject

> **Note:** This fault swaps the APIM inbound policy and requires `RG` + `APIM` env vars. There is no UI button for this scenario.

**Option A — PowerShell (Windows / VS Code terminal)**
```powershell# Run from repo root
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario apim-rate-limit -State on
```

**Option B — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh apim-rate-limit on
```

This swaps the inbound policy to `fault-rate-limit-tight.xml` (1 call / 60s). Then click **Burst x10** in the UI 2–3 times to generate traffic.

## Symptoms (Grafana)
- **D2 — APIM Health** → APIM `Status=429` panel spikes; backend `BackendStatus` columns show 0 / null (calls did not reach backend).
- **D1 — Golden Signals** → backend traffic flatlines; AppExceptions stays at 0.

## SRE Agent RCA
1. `APIMvsBackendCorrelation(15m, "submit-order")` → many 429 rows with no matching backend rows on `correlation_id`.
2. `QueryRecentAppErrors(15m, "api-service")` → empty (rules out backend).
3. APIM Azure Monitor metric `Rate Limit Exceeded` spikes (Agent reads via Azure Monitor connector).

Root cause: APIM rate-limit policy on `voice-orders` API is too tight.

## Remediation

**Option A — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
.\infra\scripts\60-fault-toggle.ps1 -Scenario apim-rate-limit -State off
```

**Option B — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh apim-rate-limit off
```

## Verification
- 429 panel returns to 0 within 30s.
- Backend traffic resumes.

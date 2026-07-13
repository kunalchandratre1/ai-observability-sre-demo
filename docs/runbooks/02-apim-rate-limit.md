# Scenario 2 — APIM-only fault (rate limit)

**Goal:** APIM blocks calls with 429s; backend stays idle and healthy. SRE Agent must conclude APIM is the cause, not the backend.

## Demo isolation (important when Scenario 1 was run just before this)

Run this quick reset sequence before injecting APIM rate-limit:

```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario exception -State off
kubectl rollout restart deployment/api-service -n app
kubectl rollout status deployment/api-service -n app --timeout=120s
```

Then verify all app-level fault flags are false before starting Scenario 2:

```powershell
$uri = "$($env:APIM_GW_URL.TrimEnd('/'))/voice/admin/faults"
$headers = @{ 'Ocp-Apim-Subscription-Key' = $env:APIM_KEY }
1..6 | ForEach-Object { Invoke-RestMethod -Method Get -Uri $uri -Headers $headers | Select-Object pod,fault_force_exception,fault_force_openai_down,fault_force_speech_down,fault_force_thirdparty_down }
```

For clean RCA narrative in the portal, start a new SRE Agent chat thread and ask with a short window (last 2-5 minutes).

## Inject

> **Note:** This fault swaps the APIM inbound policy and requires `RG` + `APIM` env vars. There is no UI button for this scenario.

**Option A — PowerShell (Windows / VS Code terminal)**
```powershell
# Run each line separately in the terminal
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
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

Prompt: **"APIM submit-order is returning 429 in the last 5 minutes. Determine APIM vs backend using only last-5-minute data and prioritize status=429 evidence."**

Expected reasoning chain (≥ 0.9 confidence):
1. `APIMvsBackendCorrelation(5m, "submit-order")` → 429 rows have no matching backend rows on `correlation_id`.
2. `QueryRecentAppErrors(5m, "api-service")` → empty or near-zero RuntimeError (rules out backend fault as primary cause).
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
- Backend traffic resumes.# Scenario 2 — APIM-only fault (rate limit)

**Goal:** APIM blocks calls with 429s; backend stays idle and healthy. SRE Agent must conclude APIM is the cause, not the backend.

## Demo isolation (important when Scenario 1 was run just before this)

Run this quick reset sequence before injecting APIM rate-limit:

```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.
infra\scripts\60-fault-toggle.ps1 -Scenario exception -State off
kubectl rollout restart deployment/api-service -n app
kubectl rollout status deployment/api-service -n app --timeout=120s
```

Then verify all app-level fault flags are false before starting Scenario 2:

```powershell
$uri = "$($env:APIM_GW_URL.TrimEnd('/'))/voice/admin/faults"
$headers = @{ 'Ocp-Apim-Subscription-Key' = $env:APIM_KEY }
1..6 | ForEach-Object { Invoke-RestMethod -Method Get -Uri $uri -Headers $headers | Select-Object pod,fault_force_exception,fault_force_openai_down,fault_force_speech_down,fault_force_thirdparty_down }
```

For clean RCA narrative in the portal, start a new SRE Agent chat thread and ask with a short window (last 2-5 minutes).

## Inject

> **Note:** This fault swaps the APIM inbound policy and requires `RG` + `APIM` env vars. There is no UI button for this scenario.

**Option A — PowerShell (Windows / VS Code terminal)**
```powershell
# Run each line separately in the terminal
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
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

Prompt: **"APIM submit-order is returning 429 in the last 5 minutes. Determine APIM vs backend using only last-5-minute data and prioritize status=429 evidence."**

Expected reasoning chain (≥ 0.9 confidence):
1. `APIMvsBackendCorrelation(5m, "submit-order")` → 429 rows have no matching backend rows on `correlation_id`.
2. `QueryRecentAppErrors(5m, "api-service")` → empty or near-zero RuntimeError (rules out backend fault as primary cause).
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

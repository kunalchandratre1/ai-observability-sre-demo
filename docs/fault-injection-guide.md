# Fault Injection Guide

Run all scenarios from `docs/verification-checklist.md` first — every baseline checkbox must be green before injecting faults.

## Environment variables (set once in your terminal)

> **Where to run these commands — local VS Code terminal (recommended) or Azure Cloud Shell?**
>
> | Terminal | When to use | Notes |
> |---|---|---|
> | **Local VS Code terminal** ✅ (recommended) | Day-to-day demo prep | `infra/scripts/.env` is auto-written by `deploy-all.ps1` — just source it once |
> | **Azure Cloud Shell** | When you don't have the repo cloned locally | Must set env vars manually each session; no local `.env` file |
>
> **Fastest path (local VS Code terminal):** The `.env` file was written automatically at the end of deployment. Just load it:
>
> ```powershell
> # PowerShell — single line, safe to copy-paste
> Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
> ```
> ```bash
> # Bash / WSL — load from .env file (one-time per terminal session)
> source infra/scripts/.env
> ```
>
> After that, `$APIM_KEY` (bash) / `$env:APIM_KEY` (PowerShell) are set and all fault scripts work without any further setup.

**If setting manually (e.g. Azure Cloud Shell):**

```powershell
$env:APIM_GW_URL = "https://aiosre-apim-demo.azure-api.net"
$env:APIM_KEY    = "<your-apim-subscription-key>"
$env:RG          = "ai-obs-sre-demo"
$env:APIM        = "aiosre-apim-demo"
$env:COSMOS_ACCOUNT = "aiosrecosmosdemo4lrdqw4e2yr2s"
```

```bash
export APIM_GW_URL="https://aiosre-apim-demo.azure-api.net"
export APIM_KEY="<your-apim-subscription-key>"
export RG="ai-obs-sre-demo"
export APIM="aiosre-apim-demo"
```

> Fetch `<your-apim-subscription-key>` with:
> ```bash
> az apim subscription list --resource-group ai-obs-sre-demo --service-name aiosre-apim-demo --query "[?contains(scope,'unlimited')].{key:primaryKey}" -o tsv
> ```

## Fault injection loop (same for every scenario)

1. **Inject** — run the toggle command
2. **Drive traffic** — click **Burst x10** in the UI (repeat a few times)
3. **Watch Grafana** — wait 30–60s for panels to react
4. **Ask SRE Agent** — use the prompt in each scenario
5. **Remediate** — run the off/reset command
6. **Verify green** — confirm dashboards return to baseline

---

## Scenario 1 — Backend API exception (not APIM)

**Goal:** APIM is healthy; backend is throwing unhandled exceptions. SRE Agent must blame the backend, not APIM, using `correlation_id` join across APIM ↔ backend.

**Runbook:** `docs/runbooks/01-backend-api-fault.md`

### Inject
Choose **any one** of the three methods — they all call the same admin endpoint:

**Option A — UI button (easiest, no terminal needed)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **Force exception**.

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
# Run from repo root
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
./infra/scripts/60-fault-toggle.ps1 -Scenario exception -State on
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh exception on
```

### Drive traffic
Click **Burst x10** in the UI 2–3 times.

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D1 | Errors per minute | Spikes (ExceptionType=RuntimeError, DependencyName empty) |
| D2 | APIM 4xx/5xx (Azure Monitor) | FailedRequests rises, BackendResponseCode=500 |
| D2 | APIM diagnostics table | ResponseCode=500, BackendResponseCode=500 — BOTH 500 |
| D1 | Latency p95 | Slight rise (exception path still runs) |

**Key signal on D2:** `ResponseCode=500` AND `BackendResponseCode=500` → fault is in backend, not APIM.

### Ask SRE Agent
```
Why are voice orders failing in the last 15 minutes?
```

**Expected reasoning chain (≥ 0.9 confidence):**
1. `QueryRecentAppErrors(15m, "api-service")` → `RuntimeError` dominates, `DependencyName` is empty
2. `APIMvsBackendCorrelation(15m, "submit-order")` → every APIM 5xx row has a matching backend exception on `correlation_id` → backend fault confirmed
3. `TraceDrilldown(<trace_id>)` → `POST /api/orders` span fails before any `dep.*` span → exception in handler, not a dependency
4. `DeploymentCorrelation(15m)` → single deployment version, no recent change → not a bad deploy

**Root cause stated by agent:** *api-service raising synthetic unhandled exception (admin fault toggle)*

### Remediate
**Option A — UI:** Click **Reset all** in the Fault toggles section.

**Option B — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
./infra/scripts/60-fault-toggle.ps1 -Scenario exception -State off
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh exception off
```

### Verify green
- [ ] D1 errors panel returns to baseline within 1 minute
- [ ] D2 APIM 5xx rate drops to 0

---

## Scenario 2 — APIM rate limit (backend silent)

**Goal:** APIM blocks calls with 429s. Backend stays completely idle (calls never reach it). SRE Agent must conclude APIM is the cause by the absence of backend logs.

**Runbook:** `docs/runbooks/02-apim-rate-limit.md`

### Inject
```bash
RG=ai-obs-sre-demo APIM=aiosre-apim-demo bash infra/scripts/60-fault-toggle.sh apim-rate-limit on
```
This swaps the inbound policy to `fault-rate-limit-tight.xml` (1 call per 60 seconds).

### Drive traffic
Click **Submit** or **Burst x10** repeatedly — most requests will get 429.

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D2 | APIM 4xx/5xx (Azure Monitor) | FailedRequests spikes with 429 |
| D2 | APIM diagnostics table | ResponseCode=429, BackendResponseCode=null/empty |
| D1 | Traffic (req/min) | Flatlines or drops (calls don't reach AKS) |
| D1 | Errors per minute | Stays at zero (no backend exceptions) |

**Key signal:** D2 shows 429 on APIM side but D1 `AppExceptions` stays at zero → calls never reached backend.

### Ask SRE Agent
```
APIM is returning errors. Is the problem in APIM or the backend?
```

**Expected reasoning:**
1. `APIMvsBackendCorrelation(15m, "submit-order")` → 429 rows have NO matching `AppExceptions` rows — calls did not reach backend
2. `QueryRecentAppErrors(15m, "api-service")` → empty → backend is healthy
3. Azure Monitor connector confirms `Rate Limit Exceeded` metric spike on APIM

**Root cause stated by agent:** *APIM `voice-orders` API rate-limit policy too restrictive — rejecting at gateway before backend*

### Remediate
```bash
RG=ai-obs-sre-demo APIM=aiosre-apim-demo bash infra/scripts/60-fault-toggle.sh apim-rate-limit off
```

### Verify green
- [ ] 429 rate drops to 0 within 30 seconds
- [ ] D1 traffic panel recovers

---

## Scenario 3 — Cosmos DB private endpoint / DNS failure

**Goal:** Worker-service cannot resolve the Cosmos DB hostname (simulates broken Private DNS Zone link). Orders enqueue but fail at write. API stays up. Service Bus queue builds up.

**Runbook:** `docs/runbooks/03-cosmos-private-endpoint.md`

### Inject
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh cosmos-dns-break on
```

### Drive traffic
Click **Burst x10** a few times. The UI cards will show `Cosmos: error` but `AzureOpenAI` and `AzureSpeech` will still be ok.

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D4 | DNS/PE resolution failures table | Fills with `ExceptionType=NameResolutionError`, message contains `invalid-dns.azure.com` |
| D4 | Cosmos write errors | Spikes |
| D4 | Successful Cosmos writes stat | Drops to 0 |
| D1 | Errors per minute | worker-service exceptions spike |
| D1 | api-service errors | Stays at zero (api-service itself is unaffected — writes are async) |
| Azure Monitor → Service Bus | Queue length / Active messages | Grows (worker keeps failing) |

### Ask SRE Agent
```
Orders are not being persisted to Cosmos. What is the root cause?
```

**Expected reasoning:**
1. `QueryDependencyErrors(15m, "Cosmos")` → 100% failure rate, `ExceptionType=NameResolutionError`
2. `TraceDrilldown(<trace_id>)` → api-service span ok through `dep.ServiceBus.send`; worker span `dep.Cosmos.upsert` fails with DNS error
3. Agent suggests verifying Private DNS Zone link and running `nslookup` from pod

**Root cause stated by agent:** *Cosmos endpoint hostname cannot resolve to private endpoint IP — Private DNS Zone link removed or DNS override misconfigured*

### Remediate
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh cosmos-dns-break off
```

### Verify green
- [ ] Worker drains the Service Bus queue
- [ ] D4 panels return to baseline within 2 minutes
- [ ] Successful Cosmos writes stat recovers

---

## Scenario 4 — Azure OpenAI endpoint unavailable ⭐ (best opening demo scenario)

**Goal:** The mandatory AI dependency (intent extraction) is down. 100% of voice orders fail at the OpenAI call. Clear, fast, high-confidence RCA.

**Runbook:** `docs/runbooks/04-openai-down.md`

### Inject
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh openai-down on
```
Or click **OpenAI down** in the UI Fault toggles section.

### Drive traffic
Submit a few orders — all will return 503 with `{"dependency":"AzureOpenAI", "status":"error"}`.

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D3 | OpenAI errors/min | Spikes to 100% of request rate |
| D3 | OpenAI latency p50/p95 | Drops to 0 (exception raised before HTTP call completes) |
| D3 | AI failures table | Fills with `DependencyName=AzureOpenAI`, `ExceptionType=DependencyError` |
| D1 | Errors per minute | Spikes with `DependencyName=AzureOpenAI` |
| D3 | Speech panels | Stay green (Speech is a separate dependency) |

### Ask SRE Agent
```
Voice orders are failing with 503. What is broken and why?
```

**Expected reasoning (confidence ≥ 0.9):**
1. `QueryRecentAppErrors(15m, "api-service")` → `DependencyError` for `DependencyName=AzureOpenAI` dominates
2. `QueryDependencyErrors(15m, "AzureOpenAI")` → 100% error rate; `AzureSpeech` healthy → single dependency confirmed
3. `APIMvsBackendCorrelation(15m)` → backend is returning 503, not APIM rejecting → fault is in backend dependency

**Root cause stated by agent:** *Azure OpenAI dependency is unavailable (synthetic toggle). Business impact: 100% of voice orders failing at intent extraction.*

### Remediate
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh openai-down off
```
Or click **Reset all** in the UI.

### Verify green
- [ ] D3 OpenAI error panels return to zero within 1 minute
- [ ] D1 error rate returns to baseline
- [ ] UI dependency cards show `AzureOpenAI: ok` again

---

## Scenario 5 — Azure Speech endpoint unavailable

**Goal:** STT/TTS is down but OpenAI is healthy. Agent must disambiguate between two AI dependencies.

**Runbook:** `docs/runbooks/05-speech-down.md`

### Inject
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh speech-down on
```

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D3 | Speech errors/min | Spikes |
| D3 | OpenAI panels | Stay green (OpenAI unaffected) |
| D1 | Errors per minute | Spikes with `DependencyName=AzureSpeech` |

### Ask SRE Agent
```
Orders are returning 503. Is it OpenAI or Speech that is down?
```

**Expected reasoning:**
1. `QueryDependencyErrors(15m, "AzureSpeech")` → 100% errors
2. `QueryDependencyErrors(15m, "AzureOpenAI")` → healthy → rules out shared identity/network issue
3. Agent attributes failure specifically to Speech endpoint

### Remediate
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh speech-down off
```

### Verify green
- [ ] D3 Speech panels green within 1 minute

---

## Scenario 6 — Third-party API unavailable (degraded, not outage)

**Goal:** External API is down but the business transaction still completes (third-party is non-fatal). Agent must classify this as **degraded** severity, not a full outage.

**Runbook:** `docs/runbooks/06-thirdparty-down.md`

### Inject
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh thirdparty-down on
```

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D5 | 3rd-party errors/min | Spikes |
| D1 | Errors per minute (AppExceptions) | Stays at zero — request still completes |
| UI per-txn card | `ThirdPartyAPI` | Shows `error` |
| UI per-txn card | All others | Show `ok` — business transaction succeeds |

**Key teaching point:** HTTP 200 returned to client despite ThirdParty failure — observable only via dependency-level monitoring, not top-level error rates.

### Ask SRE Agent
```
Third-party API is showing errors. What is the business impact?
```

**Expected reasoning:**
1. `QueryDependencyErrors(15m, "ThirdPartyAPI")` → 100% errors
2. `QueryRecentAppErrors(15m, "api-service")` → empty — no top-level exceptions
3. Agent classifies as **degraded** (not outage) — orders still processing successfully

### Remediate
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh thirdparty-down off
```

### Verify green
- [ ] D5 panels return to zero
- [ ] UI per-txn ThirdPartyAPI card shows `ok`

---

## Scenario 7 — AKS CPU saturation (cross-plane RCA)

**Goal:** Prove the agent can correlate latency increase in ADX traces with CPU saturation visible only in Managed Prometheus — a cross-plane investigation.

**Runbook:** `docs/runbooks/07-cpu-saturation.md`

### Inject
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh cpu-burn 800
```
This adds an 800ms CPU spin to every request handler.

### Drive traffic
Click **Burst x10** repeatedly to sustain load. Watch HPA react:
```powershell
kubectl get hpa -n app -w
```

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D1 | Latency p95 per dependency | Rises ~800ms across all deps (handler is slow before any dep call) |
| D1 | AKS pod CPU (Managed Prometheus) | One or more pods at >85% CPU |
| D1 | Traffic (req/min) | May drop slightly as pods are saturated |

**Key teaching point:** Latency spike visible in ADX (`AppSpans`). CPU cause visible only in Managed Prometheus. Two different data planes — agent must reason across both.

### Ask SRE Agent
```
Latency has increased by ~800ms. Is this a dependency issue or an infrastructure issue?
```

**Expected reasoning:**
1. `QueryLatencyPercentiles(30m, "api-service")` → p95 up ~800ms from baseline
2. `TraceDrilldown(<slow trace_id>)` → handler span has 800ms gap *before* any `dep.*` span → CPU-bound, not dependency-bound
3. `DeploymentCorrelation(1h)` → no new deployment version → not a code regression
4. Agent references D1 Panel 4 (Managed Prometheus CPU) to confirm infrastructure root cause

**Root cause stated by agent:** *CPU saturation on api-service pods (synthetic burn). HPA scaling in progress but not yet recovered.*

### Remediate
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh cpu-burn 0
```

### Verify green
- [ ] D1 latency p95 returns to baseline within 1–2 minutes
- [ ] D1 AKS pod CPU drops back to normal
- [ ] HPA scales back down (`kubectl get hpa -n app`)

---

## Scenario 8 — Bad deployment (regression in v2-bad)

**Goal:** A new release introduces a 1-in-3 exception. Agent uses `DeploymentCorrelation` to pinpoint the specific `DeploymentVersion` and links to the GitHub commit.

**Runbook:** `docs/runbooks/08-bad-deployment.md`

> **Note:** This scenario requires a code change + container build + kubectl rollout. More involved than the other 7.

### Inject

**Step 1 — Add regression to code:**
Edit `api/api-service/app/routers/orders.py` — add inside the order handler:
```python
import uuid as _uuid
if _uuid.uuid4().int % 3 == 0:
    raise RuntimeError("regression v2 — bad release")
```

**Step 2 — Build and push:**
```bash
TAG=v2-bad bash infra/scripts/20-build-and-push.sh
```

**Step 3 — Roll out:**
```bash
# Replace $ACR with your ACR login server name (from portal)
kubectl set image deploy/api-service -n app api=$ACR/api-service:v2-bad
kubectl rollout status deploy/api-service -n app
```

### Drive traffic
Click **Burst x10** several times. Approximately 1 in 3 requests will fail.

### Watch — Grafana
| Dashboard | Panel | Expected |
|---|---|---|
| D1 | Errors per minute | ~33% error rate (not 100%) — intermittent |
| D1 | Deployment versions stat | Shows both old version and `v2-bad` |
| D2 | APIM 5xx | ~33% of requests return 500 |

**Key signal:** Error rate is ~33% (not 100%) and errors started at the exact rollout time — strong deployment correlation.

### Ask SRE Agent
```
Error rate jumped to ~33% about 10 minutes ago. Was this caused by a deployment?
```

**Expected reasoning:**
1. `DeploymentCorrelation(1h)` → `error_rate` for `v2-bad` ≈ 0.33 vs ≈ 0 for previous version
2. `QueryRecentAppErrors(15m, "api-service")` → `RuntimeError: regression v2 — bad release`
3. GitHub connector → most recent commit modifies `orders.py` — agent surfaces commit hash and author

**Root cause stated by agent:** *Deployment `v2-bad` introduces a 1-in-3 unhandled exception in `orders.py`. Roll back to restore service.*

### Remediate
```bash
kubectl rollout undo deploy/api-service -n app
kubectl rollout status deploy/api-service -n app
```

### Verify green
- [ ] Error rate returns to ~0
- [ ] D1 deployment versions panel shows only the previous (stable) version
- [ ] No more `RuntimeError: regression v2` in D1 exceptions table

---

## Reset all faults (safety net)

If anything gets stuck or you lose track of what is active, run:

```bash
# Reset all app-level faults via admin endpoint
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=$APIM_KEY \
  bash infra/scripts/60-fault-toggle.sh exception off

# Or via UI: click "Reset all" in the Fault toggles section

# Restore APIM rate limit policy if scenario 2 was active
RG=ai-obs-sre-demo APIM=aiosre-apim-demo \
  bash infra/scripts/60-fault-toggle.sh apim-rate-limit off

# Roll back any bad deployment
kubectl rollout undo deploy/api-service -n app 2>/dev/null || true
```

Verify all dashboards return to green baseline before proceeding to the next scenario.

---

## Scenario summary

| # | Scenario | Inject command | Primary Grafana dashboard | Agent tool used | Confidence |
|---|---|---|---|---|---|
| 1 | Backend exception | `exception on` | D1, D2 | `QueryRecentAppErrors` + `APIMvsBackendCorrelation` | ≥ 0.9 |
| 2 | APIM rate limit | `apim-rate-limit on` | D2 | `APIMvsBackendCorrelation` + Azure Monitor | ≥ 0.9 |
| 3 | Cosmos DNS break | `cosmos-dns-break on` | D4 | `QueryDependencyErrors(Cosmos)` + `TraceDrilldown` | ≥ 0.9 |
| 4 ⭐ | OpenAI down | `openai-down on` | D3, D1 | `QueryDependencyErrors(AzureOpenAI)` | ≥ 0.9 |
| 5 | Speech down | `speech-down on` | D3 | `QueryDependencyErrors(AzureSpeech)` | ≥ 0.9 |
| 6 | Third-party down | `thirdparty-down on` | D5 | `QueryDependencyErrors(ThirdPartyAPI)` | 0.8 (degraded) |
| 7 | CPU saturation | `cpu-burn 800` | D1 | `QueryLatencyPercentiles` + `TraceDrilldown` | 0.8 |
| 8 | Bad deployment | Build + rollout `v2-bad` | D1 | `DeploymentCorrelation` + GitHub | ≥ 0.9 |

⭐ = recommended first scenario for demos (fastest signal, highest confidence, most audience-relevant)

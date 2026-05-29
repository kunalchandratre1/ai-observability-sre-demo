# Demo Script (speaker notes)

## Stage 0 — Setup (one-off, before the room)
1. Copy `infra/bicep/main.parameters.example.json` → `infra/bicep/main.parameters.json`; fill in prefix, location, passwords.
2. `az group create -n ai-obs-sre-demo -l australiaeast`
3. **One-click deploy**: `cd infra/scripts && .\deploy-all.ps1` (~35-45 min; idempotent).
   - Re-deploy on existing infra: `.\deploy-all.ps1 -SkipBicep`
4. Complete SRE Agent portal steps per `docs/runbooks/sre-agent-setup.md`.
5. Open the UI (`ui/public/index.html`) and paste the APIM gateway URL + a subscription key.
6. Open three tabs: **UI**, **Azure Managed Grafana** (D1), **Azure SRE Agent** chat.

## Stage 1 — Baseline (2 min)
- "This is a Voice-Order app. UI → APIM → AKS (FastAPI) → Speech + OpenAI + 3rd-party API → Service Bus → worker → Cosmos."
- Click **Submit**. Show the response card with `correlation_id`, `request_id`, `trace_id`, and per-dep outcomes (all green).
- Switch to Grafana **D1**. Run a small **Burst x10**. Latency / errors / traffic panels light up.
- Talking point: "Every signal — log, span, exception, APIM diagnostic — carries the same `correlation_id`. That is the entire trick."

## Stage 2 — Telemetry split (2 min)
- Open the data sources panel: ADX, Azure Monitor.
- D1 panel "AKS pod CPU" comes from **Container Insights** (Log Analytics InsightsMetrics via Azure Monitor datasource); all application signals come from ADX. APIM metrics from Azure Monitor (D2).
- "We deliberately did NOT shove everything into ADX. Each plane has the right tool. AKS infra metrics stay in Log Analytics via Container Insights — and the SRE Agent can query them via the Log Analytics connector."

## Stage 3 — Run all 8 fault scenarios

For each, follow the same loop:
- **Inject** (one shell command from `60-fault-toggle.sh` or a `kubectl` rollout).
- **Show Grafana symptom** (always within 30–60s).
- **Ask the SRE Agent**: "What's broken right now and why?"
- The agent runs the right Kusto tool, joins APIM ↔ backend on `correlation_id`, and produces the RCA.
- **Remediate**, then refresh dashboard to show green.

| # | Inject command | Talking point |
|---|---|---|
| 1 | `60-fault-toggle.sh exception on` | "APIM is healthy, backend isn't — agent must say so." |
| 2 | `60-fault-toggle.sh apim-rate-limit on` | "Backend silent. Agent must blame APIM." |
| 3 | `60-fault-toggle.sh cosmos-dns-break on` | "Async failure on the worker side; api stays up — show queue building." |
| 4 | `60-fault-toggle.sh openai-down on` | "Mandatory AI dep down → 503 with structured error." |
| 5 | `60-fault-toggle.sh speech-down on` | "Same shape, different dep — agent rules out OpenAI." |
| 6 | `60-fault-toggle.sh thirdparty-down on` | "Degraded, not down — agent classifies severity." |
| 7 | `60-fault-toggle.sh cpu-burn 800` | "Cross-plane RCA: traces (ADX) × CPU metric (Prometheus)." |
| 8 | `kubectl set image deploy/api-service ... v2-bad` | "DeploymentCorrelation pinpoints the bad version + GitHub commit." |

## Stage 4 — Postmortem learning (2 min)
- Open Cosmos `IncidentHistory` container — show that each scenario's RCA was persisted (scenarioId, root_cause, evidence, KQL, links).
- "Next time the same pattern shows up, the agent retrieves this incident as prior evidence — confidence climbs."

## Stage 5 — Q&A
- Likely questions:
  - *"What if APIM diagnostics are above 200 KB?"* → They get truncated. We log metadata + IDs only by policy.
  - *"How does the agent reach 90% accuracy?"* → Strict ID propagation + parameterised Kusto tools + IncidentHistory feedback loop.
  - *"What about on-prem signals?"* → Azure VM (peered "on-prem") sends to Log Analytics; future work adds a similar OTel collector path.

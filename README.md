# ai-observability-sre-demo

End-to-end Azure demo: AI-enabled observability + Root Cause Analysis using **Azure Managed Grafana** and **Azure SRE Agent**.

## What this demo proves
A single business transaction (a *Voice Order*) flows: **UI → APIM → AKS (FastAPI api-service) → Azure Speech (STT/TTS) → Azure OpenAI → Service Bus → AKS (worker-service) → Cosmos DB (Private Endpoint)**, with a 3rd-party API call in the middle. Telemetry is split across **four planes** so the SRE Agent can deterministically correlate symptoms with root causes via a stable **`correlation_id`** + W3C **`trace_id`** + APIM **`request_id`**.

```
            ┌─────────────────────── Azure Managed Grafana ───────────────────────┐
            │   ADX (logs/spans/exceptions + APIM diag) │ Container Insights (LAW)│ Az Monitor │
            └─────────────────────────────────────────────────────────────────────┘
                          ▲                          ▲                  ▲
   AKS App (OTel) → EH → ADX      Container Insights → LAW       Azure Monitor (APIM/PaaS)
                          ▲                          ▲                  ▲
 ┌──────────┐    ┌────────┴─────────┐   ┌──────────────────┐   ┌─────────────────┐
 │   UI     │ →  │   APIM (public)  │ → │  AKS (private)   │ → │ Cosmos DB (PE)  │
 │ (static) │    │  correlation +   │   │  api-service     │   │ Service Bus     │
 │          │    │  log-to-EH       │   │  worker-service  │   │ Redis, KV       │
 └──────────┘    └──────────────────┘   │  Speech, OpenAI  │   │ Speech, OpenAI  │
                                        │  3rd-party API   │   │ Azure VM ("on-prem")
                                        └──────────────────┘   └─────────────────┘
                          │
                          └──→ Azure SRE Agent (ADX connector + Log Analytics connector + GitHub repo)
```

## Repo layout
```
/api    backend FastAPI + worker (Python), Dockerfiles, K8s manifests, OTel collector
/ui     static frontend (HTML/JS) calling APIM
/infra  Bicep modules + main, APIM policies, ADX schema, Grafana dashboards, SRE tools
/docs   runbooks, demo script, postmortems, diagrams, KQL/PromQL library
```

## Quickstart — One-click deployment (Windows)

### Prerequisites
- Azure CLI (`az login` with Contributor on the subscription)
- PowerShell 7+ (`pwsh`)
- Git

### Step-by-step

```powershell
# 1. Clone the repo
git clone https://github.com/kunalchandratre1/ai-observability-sre-demo
cd ai-observability-sre-demo

# 2. Create parameters file (edit prefix, location, passwords)
Copy-Item infra/bicep/main.parameters.example.json infra/bicep/main.parameters.json
# Edit infra/bicep/main.parameters.json

# 3. Create resource group
az group create -n ai-obs-sre-demo -l australiaeast

# 4. ONE-CLICK DEPLOY (Bicep infra + build + AKS + ADX + APIM + Grafana)
cd infra/scripts
.\deploy-all.ps1
# Takes ~35-45 min first time. Re-runs are fast (all steps idempotent).
```

> **Re-deploy after first run** (infra already exists):
> ```powershell
> .\deploy-all.ps1 -SkipBicep
> ```

> **Selective re-deploy** (e.g. only Grafana dashboards):
> ```powershell
> .\deploy-all.ps1 -SkipBicep -SkipBuild -SkipAks -SkipAdx -SkipApim
> ```

### After deployment — portal steps (SRE Agent only)
Follow `docs/runbooks/sre-agent-setup.md` to complete SRE Agent connectors, knowledge files, and system prompt. Then run `docs/demo-script.md`.

## Telemetry routing (strict)
| Plane | Source | Sink | Datasource in Grafana |
|---|---|---|---|
| 1 | AKS app logs/exceptions/spans (OTel) | OTel Collector → Event Hub → **ADX** | ADX |
| 2 | AKS infra metrics (CPU/mem/restarts) | AKS omsagent → **Log Analytics** (Container Insights) | Azure Monitor (logs) |
| 3a | APIM platform metrics | **Azure Monitor** | Azure Monitor |
| 3b | APIM diagnostics (req/trace) | log-to-eventhub → EH → **ADX** | ADX |
| 4 | Cosmos / SB / KV / Redis / FW / VPN / VM | **Log Analytics** | Azure Monitor (logs) |

> **Note:** AKS Container Insights data (InsightsMetrics, Perf) flows to the same Log Analytics workspace as PaaS diagnostics (`aiosre-la-demo`). The SRE Agent queries this via the Log Analytics connector. Grafana uses the Azure Monitor datasource (Log Analytics query mode) for D1 panel 4.

## ID taxonomy (do NOT overload)
- `trace_id` / `span_id` — W3C OTel
- `correlation_id` — business txn id (one per Voice Order, stable across async)
- `request_id` — per-HTTP/APIM request

`correlation_id` is **created exactly once at the api-service boundary** if the caller didn't supply `x-correlation-id`, and propagated through APIM headers, Service Bus message application properties, and Cosmos documents.

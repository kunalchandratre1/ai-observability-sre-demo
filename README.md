# ai-observability-sre-demo

End-to-end Azure demo: AI-enabled observability + Root Cause Analysis using **Azure Managed Grafana** and **Azure SRE Agent**.

## What this demo proves
A single business transaction (a *Voice Order*) flows: **UI → APIM → AKS (FastAPI api-service) → Azure Speech (STT/TTS) → Azure OpenAI → Service Bus → AKS (worker-service) → Cosmos DB (Private Endpoint)**, with a 3rd-party API call in the middle. Telemetry is split across **four planes** so the SRE Agent can deterministically correlate symptoms with root causes via a stable **`correlation_id`** + W3C **`trace_id`** + APIM **`request_id`**.

```
            ┌─────────────────────── Azure Managed Grafana ───────────────────────┐
            │   ADX (logs/spans/exceptions + APIM diag) │ Prometheus │ Az Monitor │
            └─────────────────────────────────────────────────────────────────────┘
                          ▲                          ▲                  ▲
   AKS App (OTel) → EH → ADX        Managed Prometheus       Azure Monitor (APIM/PaaS)
                          ▲                          ▲                  ▲
 ┌──────────┐    ┌────────┴─────────┐   ┌──────────────────┐   ┌─────────────────┐
 │   UI     │ →  │   APIM (public)  │ → │  AKS (private)   │ → │ Cosmos DB (PE)  │
 │ (static) │    │  correlation +   │   │  api-service     │   │ Service Bus     │
 │          │    │  log-to-EH       │   │  worker-service  │   │ Redis, KV       │
 └──────────┘    └──────────────────┘   │  Speech, OpenAI  │   │ Speech, OpenAI  │
                                        │  3rd-party API   │   │ Azure VM ("on-prem")
                                        └──────────────────┘   └─────────────────┘
                          │
                          └──→ Azure SRE Agent (ADX connector + Kusto tools + GitHub repo)
```

## Repo layout
```
/api    backend FastAPI + worker (Python), Dockerfiles, K8s manifests, OTel collector
/ui     static frontend (HTML/JS) calling APIM
/infra  Bicep modules + main, APIM policies, ADX schema, Grafana dashboards, SRE tools
/docs   runbooks, demo script, postmortems, diagrams, KQL/PromQL library
```

## Quickstart
1. Update `infra/parameters.md` defaults if needed; create `infra/main.parameters.json`.
2. `bash infra/scripts/00-bootstrap.sh` (creates RG + service principals).
3. `bash infra/scripts/10-deploy-bicep.sh` (provisions Azure).
4. `bash infra/scripts/20-build-and-push.sh` (builds api/worker, pushes to ACR).
5. `bash infra/scripts/30-deploy-aks.sh` (kubectl apply + OTel collector + workload identity).
6. `bash infra/scripts/40-import-grafana.sh` (imports datasources + 5 dashboards).
7. `bash infra/scripts/50-create-sre-agent.sh` and follow `docs/runbooks/sre-agent-setup.md`.
8. Run a baseline transaction, then walk through `docs/demo-script.md` (8 fault scenarios).

See `docs/demo-script.md` for the full walkthrough.

## Telemetry routing (strict)
| Plane | Source | Sink | Datasource in Grafana |
|---|---|---|---|
| 1 | AKS app logs/exceptions/spans (OTel) | OTel Collector → Event Hub → **ADX** | ADX |
| 2 | AKS infra metrics | **Managed Prometheus** | Prometheus |
| 3a | APIM platform metrics | **Azure Monitor** | Azure Monitor |
| 3b | APIM diagnostics (req/trace) | log-to-eventhub → EH → **ADX** | ADX |
| 4 | Cosmos / SB / KV / Redis / FW / VPN / VM | **Log Analytics** | Azure Monitor (logs) |

## ID taxonomy (do NOT overload)
- `trace_id` / `span_id` — W3C OTel
- `correlation_id` — business txn id (one per Voice Order, stable across async)
- `request_id` — per-HTTP/APIM request

`correlation_id` is **created exactly once at the api-service boundary** if the caller didn't supply `x-correlation-id`, and propagated through APIM headers, Service Bus message application properties, and Cosmos documents.

# Architecture

## High-level

```mermaid
flowchart LR
  UI[Static UI] -->|HTTPS + x-correlation-id| APIM
  subgraph Public
    APIM[Azure API Management<br/>External, with correlation policy<br/>+ log-to-eventhub]
  end
  APIM -->|private FQDN| Ing[AKS Internal Ingress]
  subgraph AKS["AKS (private ingress, WI)"]
    api[api-service FastAPI]
    worker[worker-service]
    otel[OTel Collector]
  end
  Ing --> api
  api -->|STT/TTS| Speech[Azure Speech]
  api -->|chat.completions| OAI[Azure OpenAI]
  api -->|GET /facts| TP[Third-party API<br/>uselessfacts.jsph.pl]
  api -->|cache| Redis[(Azure Cache for Redis)]
  api -->|enqueue + AppProps| SB[(Azure Service Bus)]
  SB --> worker
  worker -->|private endpoint| Cosmos[(Cosmos DB SQL)]
  api -.OTel logs+traces+metrics.-> otel
  worker -.OTel.-> otel
  otel -->|OTLP→Kafka| EH1[(Event Hub: aks-otel)]
  APIM -->|log-to-eventhub| EH2[(Event Hub: apim-diag)]
  EH1 --> ADX[(Azure Data Explorer)]
  EH2 --> ADX
  AKS -.metrics.-> Prom[(Azure Monitor workspace<br/>Managed Prometheus)]
  Cosmos & SB & Redis & KV[(Key Vault)] & FW[(Firewall)] & VPNGW[(VPN GW)] & VM[(On-prem VM)] -.diag.-> LA[(Log Analytics)]
  APIM -.metrics.-> AM[(Azure Monitor)]

  ADX --> Grafana[Azure Managed Grafana]
  Prom --> Grafana
  AM --> Grafana
  LA --> Grafana

  ADX --> SRE[Azure SRE Agent<br/>ADX connector + Kusto tools]
  AM --> SRE
  GitHub[GitHub repo] --> SRE
  SRE --> IncCosmos[(Cosmos: IncidentHistory)]
```

## Why these choices

- **APIM External** keeps the public entrypoint while AKS stays private (internal ingress + private link via VNet integration).
- **OTel → Event Hub → ADX** is the supported, reliable path for high-cardinality app logs/spans/exceptions.  Direct ADX exporters are not first-class for OTel collector; Kafka exporter writing to Event Hub Kafka endpoint is the production pattern, with ADX **Event Hub data connection** doing JSON-line ingestion.
- **APIM diagnostics → Event Hub → ADX** gives identical query surface to the SRE Agent so it can join APIM rows with backend `AppLogs/AppExceptions/AppSpans` on `x-correlation-id` and `traceparent`.
- **Managed Prometheus** owns AKS infra metrics — keep them out of ADX.
- **Cosmos PE + Private DNS** allows scenario 3 (DNS/PE break) to be reproducible without exposing data publicly.
- **Speech + OpenAI mandatory** in business flow so scenarios 4+5 (dependency outage) become visible to SRE Agent as RCA, not as cosmetic UI errors.

## ID taxonomy & propagation

| ID | Source of truth | Propagated via |
|---|---|---|
| `correlation_id` | api-service middleware (UUIDv4 if `x-correlation-id` not provided) | Response header, OTel span attr, log field, APIM forwarded header, **SB AppProperties**, Cosmos document |
| `trace_id`/`span_id` | OTel SDK (W3C trace context) | `traceparent`/`tracestate` headers, SB AppProperties, log field |
| `request_id` | APIM `context.RequestId` (or api-service if direct) | Response header, log field, SB AppProperties |

## Failure semantics

If Speech or OpenAI is unreachable, api-service returns `503` with structured error and emits an `AppExceptions` row tagged `dependency_name=AzureOpenAI` (or `AzureSpeech`). The SRE Agent's `QueryDependencyErrors` Kusto tool fires on the spike and returns RCA with confidence > 0.8 because the failure cluster matches a single dependency.

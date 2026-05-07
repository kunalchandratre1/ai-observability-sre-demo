# Postmortems

The Azure SRE Agent appends a Cosmos document per incident into the `IncidentHistory` container with this shape:

```json
{
  "id": "<uuid>",
  "scenarioId": "S03-cosmos-pe",
  "occurredAt": "2026-05-07T03:30:00Z",
  "symptom_summary": "100% Cosmos write failures from worker; Service Bus queue length grew to 200.",
  "root_cause": "Cosmos endpoint hostname not resolving to private endpoint IP (NameResolutionError).",
  "confidence": 0.94,
  "evidence_chain": [
    { "claim": "...", "kql": "QueryDependencyErrors(15m, \"Cosmos\")", "result_summary": "..." }
  ],
  "remediation": [ "Re-link Private DNS zone privatelink.documents.azure.com to spoke VNet" ],
  "verification": [ "D4 panel green; nslookup returns 10.40.x.x" ],
  "trace_ids": [ "..." ],
  "correlation_ids": [ "..." ],
  "deployment_version": "v1.2.3",
  "links": { "grafana_d4": "...", "github_commit": "..." }
}
```

Demo postmortems will accumulate here as scenarios are re-run; the agent also queries this container to learn from prior incidents (RAG-style retrieval).

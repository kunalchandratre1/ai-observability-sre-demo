# Scenario 4 — Azure OpenAI endpoint unavailable

## Inject
```bash
bash infra/scripts/60-fault-toggle.sh openai-down on
```

## Symptoms (Grafana)
- **D3 — AI Deps** → OpenAI errors/min spikes; latency 0 (synthetic exception bypasses the call).
- **D1** → error rate rises; `dependency_name=AzureOpenAI` dominant.
- API returns `503` with `{"dependency":"AzureOpenAI", ...}` — visible on UI per-txn cards.

## SRE Agent RCA
- `QueryDependencyErrors(15m, "AzureOpenAI")` → 100% errors; ExceptionType=`DependencyError`; message references `fault_force_openai_down`.
- (In a real outage: ExceptionType would be `httpx.ConnectTimeout` / `503 Service Unavailable` — Agent should still attribute to OpenAI dependency.)

Root cause: OpenAI dependency outage (synthetic toggle); business impact = 100% of voice orders failing at intent extraction.

## Remediation
```bash
bash infra/scripts/60-fault-toggle.sh openai-down off
```

(Real-world remediation: failover to a secondary OpenAI region, raise capacity, or roll back recent network/private-endpoint changes.)

## Verification
- D3 OpenAI panels green; D1 error rate returns to baseline.

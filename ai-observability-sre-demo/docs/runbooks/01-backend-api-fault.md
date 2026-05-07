# Scenario 1 — Backend API fault only (not APIM)

**Goal:** Show that APIM is healthy while the backend is throwing unhandled exceptions, and the SRE Agent points at the backend (not APIM) using correlation_id joins.

## Pre-state
- All Grafana dashboards green.
- `GET /voice/admin/faults` returns all `false`.

## Inject
```bash
APIM_GW_URL=https://aiosre-apim-demo.azure-api.net APIM_KEY=<key> \
  bash infra/scripts/60-fault-toggle.sh exception on
# Then drive traffic from the UI ("Burst x10").
```

## Symptoms (Grafana)
- **D1 — Golden Signals** → "Errors per minute (AppExceptions)" spikes for `service=api-service`, `DependencyName=""` (synthetic exception is not dep-tagged).
- **D2 — APIM Health** → APIM `Failed Requests` rises **with backend `Status=500`**, while APIM platform metrics show no APIM-internal failure.
- **AppExceptions table** rows have `ExceptionType=RuntimeError`, `ExceptionMessage="synthetic unhandled exception (...)"`.

## SRE Agent RCA
Prompt: "Why are voice orders failing in the last 15 minutes?"

Expected reasoning chain (≥ 0.9 confidence):
1. `QueryRecentAppErrors(15m, "api-service")` → `RuntimeError` dominates with no `DependencyName`.
2. `APIMvsBackendCorrelation(15m, "submit-order")` → APIM 5xx rows have `BackendStatus=500`; on join with `AppExceptions.CorrelationId` every APIM failure has a matching backend exception.
3. `TraceDrilldown(<one trace_id>)` → `POST /api/orders` span ends in error before any `dep.*` span is created.
4. `DeploymentCorrelation(15m)` → only one deployment_version, no diff → rules out bad-deploy.

Root cause: api-service raises synthetic exception (admin fault toggle).

## Remediation
```bash
bash infra/scripts/60-fault-toggle.sh exception off
```

## Verification
- D1 errors panel returns to baseline within 1 minute.
- APIM 5xx rate drops to 0; `Successful Requests` recovers.

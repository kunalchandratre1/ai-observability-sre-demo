# Scenario 8 — Bad deployment introduces a bug

**Goal:** Show DeploymentCorrelation correctly attributes a regression to a specific `DeploymentVersion`.

## Inject
1. Edit `api/api-service/app/routers/orders.py` and force an exception on a code path that fires for ~ 30% of requests:
   ```python
   if uuid.uuid4().int % 3 == 0:
       raise RuntimeError("regression v2 — bad release")
   ```
2. Build + push:
   ```bash
   TAG=v2-bad bash infra/scripts/20-build-and-push.sh
   ```
3. Roll out:
   ```bash
   kubectl set image deploy/api-service -n app api=$ACR/api-service:v2-bad
   kubectl rollout status deploy/api-service -n app
   ```

## Symptoms
- **D1 — Golden Signals** → error rate jumps to ~ 33%; new `DeploymentVersion=v2-bad` rows in "Deployment versions" panel.
- **D2 — APIM Health** → 5xx rises (BackendStatus=500), all on the new pod set.

## SRE Agent RCA
1. `DeploymentCorrelation(1h)` → `error_rate` for `v2-bad` is ~ 0.33 vs ~ 0 for previous version.
2. `QueryRecentAppErrors(15m, "api-service")` → ExceptionMessage `regression v2 — bad release`.
3. GitHub connector → most recent commit modifies `orders.py`. Agent surfaces commit hash + author.

Root cause: bad release tagged `v2-bad` introduces a 1-in-3 unhandled exception.

## Remediation
```bash
kubectl rollout undo deploy/api-service -n app
```

## Verification
- Error rate returns to ~ 0; new traffic only hits the prior `DeploymentVersion`.
- D1 panel shows old version dominant again.

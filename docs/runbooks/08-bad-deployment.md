# Scenario 8 — Bad deployment introduces a bug

**Goal:** Show DeploymentCorrelation correctly attributes a regression to a specific `DeploymentVersion`.

## Inject

> Both images are **pre-built in ACR** — no code changes or Docker builds needed during the demo.

| Image tag | Description |
|---|---|
| `api-service:v1-good` | Clean build — no bug, ~0% error rate |
| `api-service:v2-bad` | Buggy build — raises `RuntimeError` on ~33% of requests |

**Deploy the bad image:**
```powershell
kubectl set image deploy/api-service -n app api=aiosreacrdemo4lrdqw4e2yr2s.azurecr.io/api-service:v2-bad
kubectl rollout status deploy/api-service -n app --timeout=120s
```

Then click **Burst x10** in the UI 2–3 times to generate traffic.

## Symptoms
- **D1 — Golden Signals** → error rate jumps to ~ 33%; new `DeploymentVersion=v2-bad` rows in "Deployment versions" panel.
- **D2 — APIM Health** → 5xx rises (BackendStatus=500), all on the new pod set.

## SRE Agent RCA

Prompt: **"After today's deployment, roughly one in three orders is throwing an error. Is this a code regression and which release introduced it?"**

> The symptom ("one in three") and "after today's deployment" guide the agent toward DeploymentCorrelation without naming the bug or the file.

1. `DeploymentCorrelation(1h)` → `error_rate` for `v2-bad` is ~ 0.33 vs ~ 0 for previous version.
2. `QueryRecentAppErrors(15m, "api-service")` → ExceptionMessage `regression v2 — bad release`.
3. GitHub connector → most recent commit modifies `orders.py`. Agent surfaces commit hash + author.

Root cause: bad release tagged `v2-bad` introduces a 1-in-3 unhandled exception.

## Remediation

**PowerShell:**
```powershell
kubectl set image deploy/api-service -n app api=aiosreacrdemo4lrdqw4e2yr2s.azurecr.io/api-service:v1-good
kubectl rollout status deploy/api-service -n app --timeout=120s
```

> No code changes needed — just switch back to the pre-built clean image.

## Verification
- Error rate returns to ~ 0; new traffic only hits the prior `DeploymentVersion`.
- D1 panel shows old version dominant again.

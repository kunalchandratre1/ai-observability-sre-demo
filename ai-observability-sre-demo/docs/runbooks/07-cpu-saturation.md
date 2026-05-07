# Scenario 7 — AKS CPU saturation on specific pods

**Goal:** Prove SRE Agent can correlate latency increase to CPU saturation on a specific pod (cross-plane: ADX traces × Managed Prometheus metrics).

## Inject
```bash
bash infra/scripts/60-fault-toggle.sh cpu-burn 800   # 800ms CPU spin per request
# Generate sustained traffic (UI Burst x10 a few times, or `hey`/`k6` from a workstation).
```

## Symptoms
- **D1 — Golden Signals** →
  - "Latency p95 (per dependency)" rises (handler itself is slow before any dep).
  - "AKS pod CPU (Managed Prometheus)" panel shows one pod at >85% sustained.
- **HPA** scales `api-service` from 2→ up to 10 (visible in `kubectl get hpa -n app -w`).

## SRE Agent RCA
1. `QueryLatencyPercentiles(30m, "api-service")` → p95 increased ~ 800ms above baseline starting at T0.
2. Cross-reference Grafana D1 CPU panel (Agent links it; AKS metrics live in Managed Prometheus).
3. `DeploymentCorrelation(1h)` → no new deployment_version → not a code regression.
4. `TraceDrilldown(<slow trace>)` → handler span has 800ms gap before any dep span → CPU-bound, not dependency-bound.

Root cause: sustained CPU saturation on api-service pods (synthetic burn); HPA scaling helps but does not fully recover during burn.

## Remediation
```bash
bash infra/scripts/60-fault-toggle.sh cpu-burn 0
```
Real-world fixes: bump CPU requests/limits, raise HPA targetCPU, investigate hot-path code.

## Verification
- D1 latency p95 returns to baseline.
- HPA scales back down.

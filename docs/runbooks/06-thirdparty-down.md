# Scenario 6 — Third-party API unavailable

## Inject
```bash
bash infra/scripts/60-fault-toggle.sh thirdparty-down on
```

## Symptoms
- **D5 — Third-party** → errors/min spikes.
- API still returns 200 (3rd-party is non-fatal), but per-txn UI card shows `thirdparty: error`.

## SRE Agent RCA
1. `QueryDependencyErrors(15m, "ThirdPartyAPI")` → 100% errors.
2. `QueryRecentAppErrors(15m, "api-service")` → no top-level exceptions (request still completes).
3. Agent must classify severity as **degraded** (not outage) because business txn still succeeds.

## Remediation
```bash
bash infra/scripts/60-fault-toggle.sh thirdparty-down off
```

## Verification
- D5 panels green; UI per-txn card returns to ok.

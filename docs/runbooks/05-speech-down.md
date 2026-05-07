# Scenario 5 — Azure Speech endpoint unavailable

## Inject
```bash
bash infra/scripts/60-fault-toggle.sh speech-down on
```

## Symptoms
- **D3 — AI Deps** → Speech panel errors/min spikes.
- API returns 503 with `{"dependency":"AzureSpeech", ...}`.

## SRE Agent RCA
`QueryDependencyErrors(15m, "AzureSpeech")` → 100% errors. Cross-check with `QueryDependencyErrors(15m, "AzureOpenAI")` → healthy → rules out shared identity/network root cause. Agent attributes failure to Speech endpoint specifically.

## Remediation
```bash
bash infra/scripts/60-fault-toggle.sh speech-down off
```

## Verification
- D3 Speech panels green within 1 minute.

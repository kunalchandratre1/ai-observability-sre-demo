# Runbooks index — all 8 fault scenarios

| # | Scenario | File |
|---|---|---|
| 1 | Backend API fault only (forced exception) | [01-backend-api-fault.md](01-backend-api-fault.md) |
| 2 | APIM-only fault (rate limit) | [02-apim-rate-limit.md](02-apim-rate-limit.md) |
| 3 | Cosmos Private Endpoint / DNS break | [03-cosmos-private-endpoint.md](03-cosmos-private-endpoint.md) |
| 4 | Azure OpenAI endpoint unavailable | [04-openai-down.md](04-openai-down.md) |
| 5 | Azure Speech endpoint unavailable | [05-speech-down.md](05-speech-down.md) |
| 6 | Third-party API unavailable | [06-thirdparty-down.md](06-thirdparty-down.md) |
| 7 | AKS CPU saturation (per-pod) | [07-cpu-saturation.md](07-cpu-saturation.md) |
| 8 | Bad deployment introduces a bug | [08-bad-deployment.md](08-bad-deployment.md) |

Supporting:
- [cosmos-private-endpoint.md](cosmos-private-endpoint.md) — validation steps for PE/DNS.
- [sre-agent-setup.md](sre-agent-setup.md) — Azure SRE Agent provisioning.

Every scenario follows the same 6-step contract:
**Pre-state → Inject → Symptoms (Grafana) → SRE Agent RCA → Remediation → Verification (Grafana green)**.

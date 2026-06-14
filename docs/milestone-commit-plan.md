# Milestone commit plan

> Use this when pushing to GitHub to keep history readable.

| # | Tag | Includes |
|---|---|---|
| 1 | `m1-scaffold` | README, LICENSE, .gitignore, /infra/parameters.md, /docs/architecture.md, empty subdirs |
| 2 | `m2-bicep` | All `/infra/bicep/**`, `main.parameters.example.json` |
| 3 | `m3-app` | `/api/api-service/**`, `/api/worker-service/**`, Dockerfiles, requirements |
| 4 | `m4-telemetry` | `/api/otel/**`, `/api/k8s/otel-collector.yaml`, `/api/k8s/app.yaml`, `/api/k8s/ingress-install.sh`, `/infra/adx/schema.kql`, `/infra/scripts/15-bootstrap-adx.sh` |
| 5 | `m5-ui` | `/ui/**` |
| 6 | `m6-apim` | `/infra/apim/**`, `/infra/scripts/35-apim-policies.sh`, `/infra/scripts/diagnostic-settings.json` |
| 7 | `m7-grafana` | `/infra/grafana/**`, `/infra/scripts/40-import-grafana.sh` |
| 8 | `m8-sre` | `/infra/sre-agent/**`, `/infra/scripts/50-create-sre-agent.sh`, `docs/runbooks/sre-agent-setup.md` |
| 9 | `m9-faults` | All `docs/runbooks/0?-*.md`, `cosmos-private-endpoint.md`, `infra/scripts/60-fault-toggle.sh` |
| 10 | `m10-demo` | `docs/demo-script.md`, `docs/postmortems/`, `docs/kql-prom-library.md` |

---

## Future roadmap

### Scenario 9 — Firewall rule misconfiguration (infrastructure-layer fault)

**Goal:** Prove the SRE Agent can identify a root cause that is *not* in code or deployments, but in Azure infrastructure config — specifically a firewall rule change that blocks Service Bus.

**Approach:**
- Fault toggle calls `az servicebus namespace update --public-network-access Disabled` (real Azure change, no code change)
- SDK throws a genuine `ServiceBusAuthorizationError` — not synthetic
- Agent must query **Azure Activity Log** (new `QueryAzureActivityLog` KQL tool) to find the `Microsoft.ServiceBus/namespaces/write` operation that changed `publicNetworkAccess=Disabled` and surface the caller + timestamp

**Why it's distinct from existing scenarios:**
| | Existing scenarios | Scenario 9 |
|---|---|---|
| Fault layer | Code toggle / APIM policy / DNS | Real Azure resource config change |
| Root cause evidence | OTel spans / ADX exceptions | Azure Activity Log |
| Agent tool needed | `QueryDependencyErrors`, `DeploymentCorrelation` | **`QueryAzureActivityLog`** (new) |
| Remediation | Toggle flag / kubectl rollout undo | `az servicebus namespace update --public-network-access Enabled` |

**Pre-requisite to verify before building:** Activity Logs must be exported to Log Analytics workspace (`monitoring.bicep`). If not already configured, a subscription-level diagnostic setting needs to be added.

**Files to build:**
- `infra/scripts/60-fault-toggle.ps1` and `.sh` — add `servicebus-firewall-block` case
- `infra/sre-agent/kusto-tools/QueryAzureActivityLog.kql` — new KQL tool
- SRE agent system prompt — register `QueryAzureActivityLog` as a callable tool
- `docs/runbooks/09-servicebus-firewall.md` — new runbook

---

Push with:
```bash
gh repo create kunalchandratre1/ai-observability-sre-demo --public --source . --remote origin
git add . && git commit -m "scaffold (m1)" && git tag m1-scaffold && git push -u origin main --tags
# Then commit subsequent batches with their tags.
```

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

Push with:
```bash
gh repo create kunalchandratre1/ai-observability-sre-demo --public --source . --remote origin
git add . && git commit -m "scaffold (m1)" && git tag m1-scaffold && git push -u origin main --tags
# Then commit subsequent batches with their tags.
```

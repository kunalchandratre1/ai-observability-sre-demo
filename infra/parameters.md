# Infrastructure parameters & defaults

> All defaults are demo-friendly (cheap SKUs, single zone). Override in `infra/main.parameters.json`.

| Param | Default | Notes |
|---|---|---|
| `location` | `eastus` | Region |
| `prefix` | `aiosre` | 4–6 char naming prefix |
| `env` | `demo` | suffix |
| `vnetAddressSpace` | `10.40.0.0/16` | Hub-spoke |
| `aksNodeCount` | `2` | user pool |
| `aksNodeSku` | `Standard_D4s_v5` | |
| `apimSku` | `Developer` | cheapest with VNet support |
| `apimMode` | `External` | public gateway, backend reaches AKS via internal LB |
| `cosmosConsistency` | `Session` | |
| `cosmosPrivateEndpoint` | `true` | **MUST**; private DNS zone linked |
| `serviceBusSku` | `Standard` | needs sessions/topics |
| `redisSku` | `Basic` | C0 |
| `keyVaultRbac` | `true` | |
| `speechSku` | `S0` | |
| `openAiSku` | `S0` | deploys `gpt-4o-mini` + `whisper` |
| `adxSku` | `Dev(No SLA)_Standard_E2a_v4` | single node |
| `eventHubSku` | `Standard` | 2 hubs: `apim-diag`, `aks-otel` |
| `logAnalyticsSku` | `PerGB2018` | for AKS Container Insights + non-AKS PaaS diagnostics |
| `containerInsightsEnabled` | `true` | AKS omsagent addon sends to LAW; feeds Container Insights tables (InsightsMetrics, Perf) |
| `vpnGatewayEnabled` | `false` | use VNet peering by default to save cost; toggle true to add VPN GW |
| `firewallSku` | `Standard` | |
| `onPremVmEnabled` | `true` | Azure VM in peered "on-prem" VNet |
| `acrSku` | `Standard` | |
| `workloadIdentity` | `true` | AKS OIDC + Workload Identity |

## Identity / RBAC defaults
- AKS managed identity assigned:
  - `AcrPull` on ACR
  - `Cosmos DB Built-in Data Contributor` on Cosmos
  - `Azure Service Bus Data Sender` (api) + `Receiver` (worker) on SB
  - `Cognitive Services User` on Speech + OpenAI
  - `Key Vault Secrets User` on KV
  - `Azure Event Hubs Data Sender` on `aks-otel` hub
- APIM managed identity:
  - `Azure Event Hubs Data Sender` on `apim-diag` hub
- Azure SRE Agent managed identity:
  - **`Database Viewer`** on ADX database (Reader connector)
  - `Reader` on RG / `Monitoring Reader` on Monitor workspace
  - `Reader` on APIM
  - GitHub PAT (read) for repo `kunalchandratre1/ai-observability-sre-demo`

## Naming convention
`{prefix}-{kind}-{env}` e.g. `aiosre-aks-demo`, `aiosre-apim-demo`, `aiosre-adx-demo`.

## Deployment order
1. RG + identity + KV
2. Network (VNets, subnets, peering, optional VPN, firewall, private DNS zones)
3. Monitoring (LA + Monitor workspace + Grafana + ADX cluster/db + Event Hub)
4. Data services (Cosmos+PE, SB, Redis, Speech, OpenAI, ACR, on-prem VM)
5. AKS (with OIDC + WI + ingress controller + cert-manager)
6. APIM (External, with backend pointing to AKS internal LB FQDN)
7. RBAC role assignments
8. ADX schema + EH data connections
9. App build/push + AKS apply (api, worker, OTel collector)
10. Grafana datasources + dashboards
11. SRE Agent + ADX connector + Kusto tools

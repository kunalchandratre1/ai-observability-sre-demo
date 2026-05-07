# Scenario 3 — Cosmos Private Endpoint / DNS fault

**Goal:** A misconfiguration causes Cosmos hostname resolution to fail. Worker fails Cosmos writes; orders pile up; Grafana shows DNS errors; SRE Agent identifies it.

## Inject
```bash
APIM_GW_URL=... APIM_KEY=... bash infra/scripts/60-fault-toggle.sh cosmos-dns-break on
```
This rewrites the Cosmos hostname inside the worker to `*.invalid-dns.azure.com` so the SDK cannot resolve.

(Real-world equivalent: someone removed the Private DNS Zone link, or the `privatelink.documents.azure.com` zone record was deleted. Validate with `nslookup <cosmos-account>.documents.azure.com` from any AKS pod — see [cosmos-private-endpoint.md](cosmos-private-endpoint.md).)

## Symptoms (Grafana)
- **D4 — Cosmos PE** → "DNS / PE resolution failures" table fills with `ExceptionType=NameResolutionError` (or `socket.gaierror`/`HttpRequestError`), `ExceptionMessage` containing `invalid-dns.azure.com`.
- **D1 — Golden Signals** → worker-service exceptions spike; api-service unaffected (writes are async via Service Bus).
- Service Bus queue length grows (Azure Monitor for SB).

## SRE Agent RCA
1. `QueryDependencyErrors(15m, "Cosmos")` → 100% failure rate, single `ExceptionType`.
2. `TraceDrilldown(<trace_id from one failed order>)` → api-service span ok up to `dep.ServiceBus.send`; worker span `dep.Cosmos.upsert` fails with NameResolutionError.
3. Agent suggests `nslookup` from pod (runbook command).

Root cause: Cosmos endpoint hostname does not resolve to private endpoint IP — likely Private DNS Zone link removed or DNS override misconfigured.

## Remediation
```bash
APIM_GW_URL=... APIM_KEY=... bash infra/scripts/60-fault-toggle.sh cosmos-dns-break off
```
(Real fix: re-link `privatelink.documents.azure.com` to the AKS VNet, or correct DNS overrides.)

## Verification
- Worker drains queue; D4 panels green within 2 minutes.
- `nslookup` returns 10.40.x.x (private endpoint IP).

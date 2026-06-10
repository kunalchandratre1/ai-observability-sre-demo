# Scenario 3 — Cosmos Private Endpoint / DNS fault

**Goal:** A misconfiguration causes Cosmos hostname resolution to fail. Worker fails Cosmos writes; orders pile up; Grafana shows DNS errors; SRE Agent identifies it.

## Inject

Choose **any one** of the three methods:

**Option A — UI button (easiest)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **Cosmos DNS break**.

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario cosmos-dns-break -State on
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh cosmos-dns-break on
```

This rewrites the Cosmos hostname inside the worker to `*.invalid-dns.azure.com` so the SDK cannot resolve. Then click **Burst x10** in the UI 2–3 times to generate traffic.

**What exactly happens when this toggle is on:**

1. The toggle sets `fault_force_cosmos_dns_break = true` in the api-service in-memory config (via `POST /voice/admin/faults`).
2. **api-service** — on every order, it fires a direct Cosmos write probe using the broken hostname (`aiosrecosmosdemo4lrdqw4e2yr2s.invalid-dns.azure.com`). The DNS lookup fails immediately. The error is caught, logged to ADX (`AppExceptions` with `ExceptionType=NameResolutionError`), and surfaced in the UI dependency card (`cosmos: error`). The order itself still completes and goes to Service Bus.
3. **worker-service** — when it dequeues from Service Bus and tries to write the order to Cosmos, it also uses the broken hostname. This write fails with the same DNS error. Cosmos writes pile up; the Service Bus queue grows.
4. **The order_id is still created and returned** — the fault is in the async write path, not the synchronous order acceptance path.

This simulates the real-world scenario where the **Cosmos Private Endpoint DNS Zone link is removed** from the AKS VNet — the hostname `*.documents.azure.com` no longer resolves to the private IP (`10.40.x.x`) and instead fails with `NXDOMAIN`.

## Symptoms (Grafana)
- **UI dependency card** → `cosmos: { "status": "error" }` on every order.
  > **Note on error type:** You may see either `NameResolutionError` or a `DefaultAzureCredential` auth failure depending on which part of the Cosmos SDK fails first when the hostname is unresolvable. Both are valid fault signals — the key indicator is `cosmos: error` in the UI and exception rows in ADX pointing to the broken endpoint (`invalid-dns.azure.com`).
- **D4 — Cosmos PE** → "DNS / PE resolution failures" table fills with exception rows; `ExceptionMessage` will contain `invalid-dns.azure.com`.
- **D1 — Golden Signals** → worker-service exceptions spike; api-service unaffected (writes are async via Service Bus).
- Service Bus queue length grows (Azure Monitor for SB).

## SRE Agent RCA

Prompt: **"Why are Cosmos DB writes failing? Orders are not being persisted."**

Expected reasoning chain (≥ 0.9 confidence):
1. `QueryDependencyErrors(15m, "Cosmos")` → 100% failure rate, single `ExceptionType`.
2. `TraceDrilldown(<trace_id from one failed order>)` → api-service span ok up to `dep.ServiceBus.send`; worker span `dep.Cosmos.upsert` fails with NameResolutionError.
3. Agent suggests `nslookup` from pod (runbook command).

Root cause: Cosmos endpoint hostname does not resolve to private endpoint IP — likely Private DNS Zone link removed or DNS override misconfigured.

## Remediation

**Option A — UI:** Click **Reset all** in the Fault toggles section.

**Option B — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
.\infra\scripts\60-fault-toggle.ps1 -Scenario cosmos-dns-break -State off
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh cosmos-dns-break off
```

(Real fix: re-link `privatelink.documents.azure.com` to the AKS VNet, or correct DNS overrides.)

## Verification
- Worker drains queue; D4 panels green within 2 minutes.
- `nslookup` returns 10.40.x.x (private endpoint IP).

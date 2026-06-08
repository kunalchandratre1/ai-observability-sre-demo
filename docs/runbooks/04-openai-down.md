# Scenario 4 — Azure OpenAI endpoint unavailable

## Inject

Choose **any one** of the three methods:

**Option A — UI button (easiest)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **OpenAI down**.

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario openai-down -State on
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh openai-down on
```

Then click **Burst x10** in the UI 2–3 times to generate traffic.

## Symptoms (Grafana)
- **D3 — AI Deps** → OpenAI errors/min spikes; latency 0 (synthetic exception bypasses the call).
- **D1** → error rate rises; `dependency_name=AzureOpenAI` dominant.
- API returns `503` with `{"dependency":"AzureOpenAI", ...}` — visible on UI per-txn cards.

## SRE Agent RCA
- `QueryDependencyErrors(15m, "AzureOpenAI")` → 100% errors; ExceptionType=`DependencyError`; message references `fault_force_openai_down`.
- (In a real outage: ExceptionType would be `httpx.ConnectTimeout` / `503 Service Unavailable` — Agent should still attribute to OpenAI dependency.)

Root cause: OpenAI dependency outage (synthetic toggle); business impact = 100% of voice orders failing at intent extraction.

## Remediation

**Option A — UI:** Click **Reset all** in the Fault toggles section.

**Option B — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
.\infra\scripts\60-fault-toggle.ps1 -Scenario openai-down -State off
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh openai-down off
```

(Real-world remediation: failover to a secondary OpenAI region, raise capacity, or roll back recent network/private-endpoint changes.)

## Verification
- D3 OpenAI panels green; D1 error rate returns to baseline.

# Scenario 6 — Third-party API unavailable

## Inject

Choose **any one** of the three methods:

**Option A — UI button (easiest)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **3rd-party down**.

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario thirdparty-down -State on
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh thirdparty-down on
```

Then click **Burst x10** in the UI 2–3 times to generate traffic.

## Symptoms
- **D5 — Third-party** → errors/min spikes.
- API still returns 200 (3rd-party is non-fatal), but per-txn UI card shows `thirdparty: error`.

## SRE Agent RCA
1. `QueryDependencyErrors(15m, "ThirdPartyAPI")` → 100% errors.
2. `QueryRecentAppErrors(15m, "api-service")` → no top-level exceptions (request still completes).
3. Agent must classify severity as **degraded** (not outage) because business txn still succeeds.

## Remediation

**Option A — UI:** Click **Reset all** in the Fault toggles section.

**Option B — PowerShell:**
```powershell
.\infra\scripts\60-fault-toggle.ps1 -Scenario thirdparty-down -State off
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh thirdparty-down off
```

## Verification
- D5 panels green; UI per-txn card returns to ok.

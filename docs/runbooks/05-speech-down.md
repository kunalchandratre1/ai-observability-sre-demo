# Scenario 5 — Azure Speech endpoint unavailable

## Inject

Choose **any one** of the three methods:

**Option A — UI button (easiest)**
> In the browser at `https://aiosre-ui-demo.azurewebsites.net`, scroll to **Fault toggles** → click **Speech down**.

**Option B — PowerShell (Windows / VS Code terminal)**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
Get-Content infra/scripts/.env | ForEach-Object { if ($_ -match '^([^#][^=]*)=(.+)') { [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process') } }
.\infra\scripts\60-fault-toggle.ps1 -Scenario speech-down -State on
```

**Option C — Bash / WSL**
```bash
source infra/scripts/.env
bash infra/scripts/60-fault-toggle.sh speech-down on
```

Then click **Burst x10** in the UI 2–3 times to generate traffic.

## Symptoms
- **D3 — AI Deps** → Speech panel errors/min spikes.
- API returns 503 with `{"dependency":"AzureSpeech", ...}`.

## SRE Agent RCA

Prompt: **"Customers are calling in to place orders but the system isn't recognising what they're saying at all — it's as if the voice isn't being heard. No orders are going through. What's wrong?"**

> "Voice isn't being heard" and "not recognising" point to the speech transcription layer specifically, not order processing or AI reasoning. The agent must trace which dependency fails first in the request pipeline.

Expected reasoning chain (≥ 0.9 confidence):
`QueryDependencyErrors(15m, "AzureSpeech")` → 100% errors. Cross-check with `QueryDependencyErrors(15m, "AzureOpenAI")` → healthy → rules out shared identity/network root cause. Agent attributes failure to Speech endpoint specifically.

## Remediation

**Option A — UI:** Click **Reset all** in the Fault toggles section.

**Option B — PowerShell:**
```powershell
Set-Location "D:\Customers\Bajaj Finance\End To End Monitoring\SRE Grafana Demo\ai-observability-sre-demo"
.\infra\scripts\60-fault-toggle.ps1 -Scenario speech-down -State off
```

**Option C — Bash:**
```bash
bash infra/scripts/60-fault-toggle.sh speech-down off
```

## Verification
- D3 Speech panels green within 1 minute.

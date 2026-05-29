#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Toggle fault injection scenarios for the AI Observability SRE demo.

.DESCRIPTION
    Injects or removes a specific fault to trigger observable symptoms in Grafana
    and prompt the SRE Agent to run an RCA investigation.

    Usage pattern: inject -> observe Grafana -> ask SRE Agent -> remediate -> verify green.

.PARAMETER Scenario
    Fault scenario to toggle:
      exception        - Force backend API to throw unhandled exceptions on every request
      apim-rate-limit  - Apply tight rate-limit policy to APIM (4 req/min per IP)
      cosmos-dns-break - Break Cosmos DB DNS resolution (simulates PE misconfiguration)
      openai-down      - Force backend to return OpenAI-unavailable errors
      speech-down      - Force backend to return Speech-unavailable errors
      thirdparty-down  - Force backend to fail all third-party API calls
      cosmos-throttle  - Lower Cosmos RU throughput to 400 and trigger burst writes (429s)
      cpu-burn         - Add artificial CPU burn (extra busy-wait) to each request

.PARAMETER State
    "on" to inject the fault, "off" to remove it.
    For cpu-burn, pass the number of milliseconds (e.g., "800").

.PARAMETER ApimGatewayUrl
    APIM gateway base URL. Reads from env APIM_GW_URL if not supplied.

.PARAMETER ApimKey
    APIM subscription key. Reads from env APIM_KEY if not supplied.

.PARAMETER ResourceGroup
    Resource group (needed for apim-rate-limit and cosmos-throttle). Default: ai-obs-sre-demo

.EXAMPLE
    # Inject backend exception fault
    .\60-fault-toggle.ps1 -Scenario exception -State on

.EXAMPLE
    # Clear CPU burn
    .\60-fault-toggle.ps1 -Scenario cpu-burn -State 0

.EXAMPLE
    # Apply tight APIM rate limit
    .\60-fault-toggle.ps1 -Scenario apim-rate-limit -State on
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet(
        'exception','apim-rate-limit','cosmos-dns-break',
        'openai-down','speech-down','thirdparty-down',
        'cosmos-throttle','cpu-burn'
    )]
    [string] $Scenario,

    [Parameter(Mandatory)]
    [string] $State,

    [string] $ApimGatewayUrl = $env:APIM_GW_URL,
    [string] $ApimKey        = $env:APIM_KEY,
    [string] $ResourceGroup  = 'ai-obs-sre-demo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Validate APIM params where needed
function Invoke-AdminFault([hashtable]$Body) {
    if (-not $ApimGatewayUrl) { throw "APIM_GW_URL not set. Pass -ApimGatewayUrl or set env var APIM_GW_URL." }
    if (-not $ApimKey)        { throw "APIM_KEY not set. Pass -ApimKey or set env var APIM_KEY." }
    $uri     = "$($ApimGatewayUrl.TrimEnd('/'))/voice/admin/faults"
    $headers = @{ 'Ocp-Apim-Subscription-Key' = $ApimKey; 'Content-Type' = 'application/json' }
    $json    = $Body | ConvertTo-Json -Compress
    Write-Host "  POST $uri"
    Write-Host "  Body: $json"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $json
    Write-Host "  Response: $($resp | ConvertTo-Json -Compress)"
}

Write-Host ""
Write-Host "=== Fault Toggle: $Scenario -> $State ==="

switch ($Scenario) {
    'exception' {
        Invoke-AdminFault @{ fault_force_exception = ($State -eq 'on') }
    }
    'openai-down' {
        Invoke-AdminFault @{ fault_force_openai_down = ($State -eq 'on') }
    }
    'speech-down' {
        Invoke-AdminFault @{ fault_force_speech_down = ($State -eq 'on') }
    }
    'thirdparty-down' {
        Invoke-AdminFault @{ fault_force_thirdparty_down = ($State -eq 'on') }
    }
    'cosmos-dns-break' {
        Invoke-AdminFault @{ fault_force_cosmos_dns_break = ($State -eq 'on') }
    }
    'cpu-burn' {
        $ms = [int]$State
        Invoke-AdminFault @{ fault_extra_cpu_burn_ms = $ms }
    }
    'cosmos-throttle' {
        $rg          = $ResourceGroup
        $cosmosName  = (az cosmosdb list -g $rg -o json | ConvertFrom-Json)[0].name
        if ($State -eq 'on') {
            Write-Host "  Setting Cosmos throughput to 400 RU (minimum)..."
            az cosmosdb sql database throughput update `
                -g $rg --account-name $cosmosName --name orders `
                --throughput 400 -o none
            Invoke-AdminFault @{ fault_cosmos_throttle = $true }
        } else {
            Write-Host "  Clearing cosmos-throttle signal..."
            Invoke-AdminFault @{ fault_cosmos_throttle = $false }
        }
    }
    'apim-rate-limit' {
        $rg      = $ResourceGroup
        $apimName = (az apim list -g $rg -o json | ConvertFrom-Json)[0].name
        $policyDir = Join-Path $ScriptDir '..' 'apim' 'policies'
        if ($State -eq 'on') {
            $policyFile = Resolve-Path (Join-Path $policyDir 'fault-rate-limit-tight.xml')
            Write-Host "  Applying tight rate-limit policy to APIM $apimName..."
            az apim api policy create-or-update -g $rg --service-name $apimName `
                --api-id voice-orders `
                --policy-content (Get-Content $policyFile -Raw) `
                --policy-format xml -o none
            Write-Host "  Rate-limit fault ON. Now only 4 req/min per caller IP allowed."
        } else {
            $policyFile = Resolve-Path (Join-Path $policyDir 'inbound-correlation.xml')
            Write-Host "  Restoring normal APIM policy on $apimName..."
            az apim api policy create-or-update -g $rg --service-name $apimName `
                --api-id voice-orders `
                --policy-content (Get-Content $policyFile -Raw) `
                --policy-format xml -o none
            Write-Host "  Rate-limit fault OFF. Normal policy restored."
        }
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host ""
Write-Host "Observe in Grafana (30-60s delay):"
switch ($Scenario) {
    'exception'        { Write-Host "  D1: Errors per minute spike | D1: Top recent exceptions table" }
    'apim-rate-limit'  { Write-Host "  D2: APIM 4xx rate spike | D2: Status by operation panel" }
    'cosmos-dns-break' { Write-Host "  D4: DNS/PE resolution failures | D4: Cosmos write errors" }
    'openai-down'      { Write-Host "  D3: OpenAI errors/min spike | D3: AI-dep failures table" }
    'speech-down'      { Write-Host "  D3: Speech errors/min spike | D3: AI-dep failures table" }
    'thirdparty-down'  { Write-Host "  D5: 3rd-party errors/min | D5: Recent 3rd-party failures" }
    'cosmos-throttle'  { Write-Host "  D4: Cosmos write errors (429s) | D4: Cosmos latency spike" }
    'cpu-burn'         { Write-Host "  D1: AKS pod CPU panel | D1: Latency p95 increase" }
}
Write-Host ""
Write-Host "Then ask SRE Agent: 'What is broken right now and what is the root cause?'"
Write-Host ""
if ($State -eq 'on') {
    Write-Host "To remediate: run same command with -State off"
}

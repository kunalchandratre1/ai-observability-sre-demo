#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Injects APIM into the VNet subnet 'snet-apim' in External mode.
    Must be run AFTER Bicep deploys the VNet/subnet/NSG but BEFORE the
    application workload steps that rely on APIM reaching the AKS internal LB.

.DESCRIPTION
    APIM Developer SKU VNet injection (External mode) takes 30-45 minutes.
    This script:
      1. Verifies the NSG on snet-apim has all required APIM management rules.
      2. Triggers az rest PUT to inject APIM into the VNet.
      3. Polls provisioning state every 60s until Succeeded or timeout (60 min).
    Safe to re-run — if APIM is already VNet-injected it exits immediately.

.PARAMETER ResourceGroup
    Azure resource group. Default: ai-obs-sre-demo

.PARAMETER VNetName
    Name of the VNet that contains snet-apim. Default: auto-detected from RG.

.PARAMETER SubnetName
    Subnet to inject APIM into. Default: snet-apim

.PARAMETER TimeoutMinutes
    Maximum minutes to wait for provisioning. Default: 60

.EXAMPLE
    .\11-apim-vnet-inject.ps1
    .\11-apim-vnet-inject.ps1 -ResourceGroup ai-obs-sre-demo
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup   = 'ai-obs-sre-demo',
    [string] $VNetName        = '',
    [string] $SubnetName      = 'snet-apim',
    [int]    $TimeoutMinutes  = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "============================================================"
Write-Host "  APIM VNet Injection (External mode)"
Write-Host "  ResourceGroup : $ResourceGroup"
Write-Host "============================================================"

$rg = $ResourceGroup
$subId = az account show --query id -o tsv

# ── Discover APIM ─────────────────────────────────────────────────────────────
$apimName = (az apim list -g $rg -o json | ConvertFrom-Json)[0].name
Write-Host "  APIM instance : $apimName"

# ── Check if already injected ─────────────────────────────────────────────────
$apimJson = az apim show -g $rg -n $apimName -o json | ConvertFrom-Json
$currentVnetType = $apimJson.virtualNetworkType
$currentVnetId   = $apimJson.virtualNetworkConfiguration.vnetid

if ($currentVnetType -eq 'External' -and $currentVnetId -ne '00000000-0000-0000-0000-000000000000' -and $currentVnetId) {
    Write-Host "  APIM is already VNet-injected (External, vnetid=$currentVnetId). Nothing to do." -ForegroundColor Green
    exit 0
}

# ── Discover VNet ─────────────────────────────────────────────────────────────
if (-not $VNetName) {
    $vnets = az network vnet list -g $rg -o json | ConvertFrom-Json
    $VNetName = ($vnets | Where-Object { $_.name -notlike '*onprem*' } | Select-Object -First 1).name
    if (-not $VNetName) { throw "Could not auto-detect VNet in RG '$rg'. Pass -VNetName explicitly." }
}
Write-Host "  VNet          : $VNetName"

$subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$VNetName/subnets/$SubnetName"
Write-Host "  Subnet        : $subnetId"

# ── Ensure required NSG rules on snet-apim ────────────────────────────────────
Write-Host ""
Write-Host "[1/3] Verifying NSG rules on $SubnetName..."

$subnetInfo = az network vnet subnet show -g $rg --vnet-name $VNetName --name $SubnetName -o json | ConvertFrom-Json
$nsgId = $subnetInfo.networkSecurityGroup.id
if (-not $nsgId) {
    Write-Warning "  No NSG attached to $SubnetName. APIM VNet injection requires an NSG with port 3443 open from ApiManagement service tag."
    Write-Warning "  Continuing — you may need to manually attach an NSG."
} else {
    $nsgName = ($nsgId -split '/')[-1]
    Write-Host "  NSG: $nsgName"

    $existingRules = az network nsg rule list -g $rg --nsg-name $nsgName -o json | ConvertFrom-Json

    # Required inbound rules for APIM VNet injection
    $required = @(
        @{ name='Allow-APIM-Management';    priority=100; dir='Inbound';  src='ApiManagement';      port='3443'; access='Allow' },
        @{ name='Allow-HTTPS-Inbound';      priority=110; dir='Inbound';  src='Internet';           port='443';  access='Allow' },
        @{ name='Allow-AzureLoadBalancer';  priority=120; dir='Inbound';  src='AzureLoadBalancer';  port='6390'; access='Allow' },
        @{ name='Allow-Storage-Outbound';   priority=100; dir='Outbound'; dest='Storage';           port='443';  access='Allow' },
        @{ name='Allow-SQL-Outbound';       priority=110; dir='Outbound'; dest='Sql';               port='1433'; access='Allow' },
        @{ name='Allow-KeyVault-Outbound';  priority=120; dir='Outbound'; dest='AzureKeyVault';     port='443';  access='Allow' },
        @{ name='Allow-EventHub-Outbound';  priority=130; dir='Outbound'; dest='EventHub';          port='5671'; access='Allow' },
        @{ name='Allow-EventHub-5672';      priority=131; dir='Outbound'; dest='EventHub';          port='5672'; access='Allow' },
        @{ name='Allow-Monitor-Outbound';   priority=132; dir='Outbound'; dest='AzureMonitor';      port='1886'; access='Allow' }
    )

    foreach ($rule in $required) {
        $existing = $existingRules | Where-Object { $_.name -eq $rule.name }
        if ($existing) {
            Write-Host "  [OK] Rule '$($rule.name)' exists"
        } else {
            Write-Host "  [+] Creating NSG rule '$($rule.name)'..."
            if ($rule.dir -eq 'Inbound') {
                az network nsg rule create -g $rg --nsg-name $nsgName `
                    --name $rule.name --priority $rule.priority --direction $rule.dir `
                    --source-address-prefix $rule.src --source-port-range '*' `
                    --destination-address-prefix '*' --destination-port-range $rule.port `
                    --protocol Tcp --access $rule.access --output none
            } else {
                az network nsg rule create -g $rg --nsg-name $nsgName `
                    --name $rule.name --priority $rule.priority --direction $rule.dir `
                    --source-address-prefix 'VirtualNetwork' --source-port-range '*' `
                    --destination-address-prefix $rule.dest --destination-port-range $rule.port `
                    --protocol Tcp --access $rule.access --output none
            }
            Write-Host "  [OK] Created '$($rule.name)'"
        }
    }
}

# ── Trigger VNet injection via az rest PUT ────────────────────────────────────
Write-Host ""
Write-Host "[2/3] Triggering APIM VNet injection (External mode)..."
Write-Host "      This takes 30-45 minutes. Polling every 60s..."
Write-Host "      Started: $(Get-Date -Format 'HH:mm:ss')"

$apimResourceId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName"

# Build the PUT body using the current APIM config + VNet injection
$putBody = @{
    location   = $apimJson.location
    sku        = @{ name = $apimJson.sku.name; capacity = $apimJson.sku.capacity }
    properties = @{
        publisherEmail             = $apimJson.publisherEmail
        publisherName              = $apimJson.publisherName
        virtualNetworkType         = 'External'
        virtualNetworkConfiguration = @{ subnetResourceId = $subnetId }
    }
} | ConvertTo-Json -Depth 5

$putBodyFile = Join-Path $env:TEMP "apim-vnet-inject.json"
$putBody | Set-Content $putBodyFile -Encoding UTF8

az rest --method PUT `
    --url "https://management.azure.com$apimResourceId`?api-version=2023-05-01-preview" `
    --body "@$putBodyFile" `
    --output none 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to trigger APIM VNet injection. Check the error above."
}

# ── Poll until Succeeded ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/3] Polling APIM provisioning state (timeout: $TimeoutMinutes min)..."

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastState = ''

while ((Get-Date) -lt $deadline) {
    Start-Sleep 60
    $state = az apim show -g $rg -n $apimName --query "{ps:provisioningState, vt:virtualNetworkType, vid:virtualNetworkConfiguration.vnetid}" -o json 2>$null | ConvertFrom-Json
    $ps    = $state.ps
    $vt    = $state.vt
    $vid   = $state.vid

    if ($ps -ne $lastState) {
        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  provisioningState=$ps  vnetType=$vt  vnetId=$vid"
        $lastState = $ps
    }

    if ($ps -eq 'Succeeded' -and $vt -eq 'External' -and $vid -ne '00000000-0000-0000-0000-000000000000') {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  APIM VNet injection SUCCEEDED!" -ForegroundColor Green
        Write-Host "  vnetType = External" -ForegroundColor Green
        Write-Host "  vnetId   = $vid" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host ""

        # Show private IP if available
        $privateIps = az apim show -g $rg -n $apimName --query "privateIpAddresses" -o json 2>$null | ConvertFrom-Json
        if ($privateIps) {
            Write-Host "  APIM private IP(s): $($privateIps -join ', ')"
        }
        Write-Host "  APIM gateway URL  : $($apimJson.gatewayUrl)"
        exit 0
    }

    if ($ps -eq 'Failed') {
        Write-Host ""
        Write-Error "APIM provisioning FAILED. Check Azure Portal > Activity Log for details."
    }
}

Write-Error "APIM VNet injection timed out after $TimeoutMinutes minutes. Last state: $lastState. Check portal."

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
$currentSubnet   = $apimJson.virtualNetworkConfiguration?.subnetResourceId

# External mode does NOT populate privateIpAddresses — success is subnet being set
if ($currentVnetType -eq 'External' -and $currentSubnet) {
    Write-Host "  APIM is already VNet-injected (External mode, subnet=$currentSubnet). Nothing to do." -ForegroundColor Green
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

    # Required rules per https://learn.microsoft.com/en-us/azure/api-management/api-management-using-with-vnet (External mode)
    $required = @(
        # ── Inbound ──────────────────────────────────────────────────────────────
        @{ name='Allow-APIM-Management';         priority=100; dir='Inbound';  src='ApiManagement';       port='3443'; access='Allow' },
        @{ name='Allow-HTTP-Inbound';            priority=105; dir='Inbound';  src='Internet';            port='80';   access='Allow' },  # HTTP client access (External)
        @{ name='Allow-HTTPS-Inbound';           priority=110; dir='Inbound';  src='Internet';            port='443';  access='Allow' },  # HTTPS client access
        @{ name='Allow-AzureLoadBalancer';       priority=120; dir='Inbound';  src='AzureLoadBalancer';   port='6390'; access='Allow' },  # Azure infra LB
        @{ name='Allow-TrafficManager-Inbound';  priority=125; dir='Inbound';  src='AzureTrafficManager'; port='443';  access='Allow' },  # Traffic Manager (multi-region)
        # ── Outbound ─────────────────────────────────────────────────────────────
        @{ name='Allow-Storage-Outbound';        priority=100; dir='Outbound'; dest='Storage';            port='443';  access='Allow' },  # Core service dependency
        @{ name='Allow-SQL-Outbound';            priority=110; dir='Outbound'; dest='Sql';                port='1433'; access='Allow' },  # Core service dependency
        @{ name='Allow-KeyVault-Outbound';       priority=120; dir='Outbound'; dest='AzureKeyVault';      port='443';  access='Allow' },  # Core service dependency
        @{ name='Allow-EventHub-Outbound';       priority=130; dir='Outbound'; dest='EventHub';           port='5671'; access='Allow' },  # AMQP
        @{ name='Allow-EventHub-5672-Outbound';  priority=131; dir='Outbound'; dest='EventHub';           port='5672'; access='Allow' },  # AMQP alternate port
        @{ name='Allow-Monitor-1886-Outbound';   priority=132; dir='Outbound'; dest='AzureMonitor';       port='1886'; access='Allow' },  # Diagnostics & metrics
        @{ name='Allow-Monitor-443-Outbound';    priority=133; dir='Outbound'; dest='AzureMonitor';       port='443';  access='Allow' },  # Resource Health & App Insights
        @{ name='Allow-CertValidation-Outbound'; priority=134; dir='Outbound'; dest='Internet';           port='80';   access='Allow' },  # MS & customer cert validation
        @{ name='Allow-HTTP-Backend-Outbound';   priority=140; dir='Outbound'; dest='VirtualNetwork';     port='80';   access='Allow' }   # APIM → AKS internal ingress
    )

    foreach ($rule in $required) {
        $existing = $existingRules | Where-Object { $_.name -eq $rule.name }
        if (-not $existing) {
            # Handle legacy name: Allow-Monitor-Outbound was renamed to Allow-Monitor-1886-Outbound
            if ($rule.name -eq 'Allow-Monitor-1886-Outbound') {
                $legacy = $existingRules | Where-Object { $_.name -eq 'Allow-Monitor-Outbound' }
                if ($legacy) {
                    Write-Host "  [~] Renaming legacy 'Allow-Monitor-Outbound' -> 'Allow-Monitor-1886-Outbound'..."
                    az network nsg rule update -g $rg --nsg-name $nsgName --name 'Allow-Monitor-Outbound' --new-rule-name 'Allow-Monitor-1886-Outbound' --output none
                    Write-Host "  [OK] Renamed to 'Allow-Monitor-1886-Outbound'"
                    continue
                }
            }
        }
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

# stv2 platform requires a Standard SKU Public IP for External VNet injection.
# Create one if it doesn't exist yet.
$pipName = "$apimName-pip"
$existingPip = az network public-ip show -g $rg -n $pipName -o json 2>$null | ConvertFrom-Json
if (-not $existingPip) {
    Write-Host "  [+] Creating Standard SKU Public IP '$pipName' (required for stv2 External VNet injection)..."
    az network public-ip create -g $rg -n $pipName `
        --sku Standard --allocation-method Static `
        --location $apimJson.location --dns-name $pipName `
        --output none
    Write-Host "  [OK] Created '$pipName'"
} else {
    Write-Host "  [OK] Public IP '$pipName' already exists"
}
$pipId = az network public-ip show -g $rg -n $pipName --query id -o tsv

# Build the PUT body: stv2 External mode requires publicIpAddressId
$putBody = @{
    location   = $apimJson.location
    sku        = @{ name = $apimJson.sku.name; capacity = $apimJson.sku.capacity }
    properties = @{
        publisherEmail              = $apimJson.publisherEmail
        publisherName               = $apimJson.publisherName
        virtualNetworkType          = 'External'
        publicIpAddressId           = $pipId
        virtualNetworkConfiguration = @{ subnetResourceId = $subnetId }
    }
} | ConvertTo-Json -Depth 5

$putBodyFile = Join-Path $env:TEMP "apim-vnet-inject.json"
$putBody | Set-Content $putBodyFile -Encoding UTF8

az rest --method PUT `
    --url "https://management.azure.com$apimResourceId`?api-version=2022-08-01" `
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
    # NOTE: External VNet mode does NOT populate privateIpAddresses — that is Internal mode only.
    # Success is indicated by provisioningState=Succeeded + vnetType=External + subnet set.
    $state  = az apim show -g $rg -n $apimName --query "{ps:provisioningState, vt:virtualNetworkType, subnet:virtualNetworkConfiguration.subnetResourceId, pubIps:publicIpAddresses}" -o json 2>$null | ConvertFrom-Json
    $ps     = $state.ps
    $vt     = $state.vt
    $subnet = $state.subnet
    $pubIps = $state.pubIps

    if ($ps -ne $lastState) {
        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  provisioningState=$ps  vnetType=$vt  subnet=$(if ($subnet) { 'set' } else { 'null' })  publicIPs=$($pubIps -join ',')"
        $lastState = $ps
    }

    # External mode: success = Succeeded + External + subnet resource ID is populated
    if ($ps -eq 'Succeeded' -and $vt -eq 'External' -and $subnet) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  APIM VNet injection SUCCEEDED!" -ForegroundColor Green
        Write-Host "  vnetType   = External (privateIpAddresses is null by design)" -ForegroundColor Green
        Write-Host "  subnet     = $subnet" -ForegroundColor Green
        Write-Host "  publicIPs  = $($pubIps -join ', ')" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  APIM gateway URL  : $($apimJson.gatewayUrl)"
        Write-Host "  Backend calls use private DIPs from snet-apim (10.40.5.0/24)"
        exit 0
    }

    if ($ps -eq 'Failed') {
        Write-Host ""
        Write-Error "APIM provisioning FAILED. Check Azure Portal > Activity Log for details."
    }
}

Write-Error "APIM VNet injection timed out after $TimeoutMinutes minutes. Last state: $lastState. Check portal."

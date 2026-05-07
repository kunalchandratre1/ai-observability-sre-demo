# Cosmos DB Private Endpoint validation

## Goal
Prove that the AKS pods resolve `<cosmos-account>.documents.azure.com` to the **private endpoint IP** (in subnet `snet-pe`), and not to a public IP.

## Validate from inside the cluster
```bash
kubectl run nettest --rm -it --image=nicolaka/netshoot --restart=Never -- \
  bash -c "nslookup <cosmos-account>.documents.azure.com; getent hosts <cosmos-account>.documents.azure.com"
```
Expected:
- The CNAME chain ends at `*.privatelink.documents.azure.com`.
- The resolved IP is in the spoke VNet PE subnet (e.g. `10.40.4.x`).

## If it fails
Likely causes:
1. Private DNS zone `privatelink.documents.azure.com` is not linked to the spoke VNet.
2. Custom DNS server used by AKS does not forward to Azure (168.63.129.16).
3. Cosmos `publicNetworkAccess` is `Enabled`, but the public DNS record was removed unexpectedly.

Fix:
```bash
az network private-dns link vnet create -g ai-obs-sre-demo -n cosmos-link \
  -z privatelink.documents.azure.com -v aiosre-vnet-demo --registration-enabled false
```

## App-side fault injection (Scenario 3)
Toggle `fault_force_cosmos_dns_break=true` via `/api/admin/faults` (or the UI button) to simulate the same failure mode without touching real Azure DNS. The worker rewrites the hostname to `*.invalid-dns.azure.com` and the Cosmos SDK fails with `NameResolutionError`.

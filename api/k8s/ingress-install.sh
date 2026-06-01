# Install nginx-ingress with internal LB so APIM (same VNet) can reach it via private IP.
# Run this once per cluster, BEFORE applying app.yaml.
#
# IMPORTANT (Azure Standard LB): The ILB health probe must be TCP, not HTTP.
# Azure Standard LB defaults to HTTP probe with path "/" — nginx returns 404 for "/"
# (no default backend), which marks all backends unhealthy and drops connections.
# Fix: set health probe protocol to TCP so the probe only checks port reachability.
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-basic --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-protocol"=tcp \
  --set controller.service.loadBalancerIP="" \
  --set controller.metrics.enabled=true \
  --set controller.podAnnotations."prometheus\.io/scrape"="true" \
  --set controller.podAnnotations."prometheus\.io/port"="10254"

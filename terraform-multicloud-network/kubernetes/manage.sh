#!/usr/bin/env bash
set -euo pipefail
ACTION="${1:-}"
CONFIG="${2:-}"
VALUES="${3:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ "$ACTION" == install || "$ACTION" == uninstall ]] || { echo 'Usage: manage.sh install|uninstall platform.json [routes.yaml]'; exit 1; }
test -f "$CONFIG"
command -v jq >/dev/null
command -v helm >/dev/null
command -v kubectl >/dev/null
CLOUD=$(jq -er .cloud "$CONFIG")
TARGET_ENV=$(jq -er .environment "$CONFIG")
CLUSTER=$(jq -er .cluster_name "$CONFIG")
REGION=$(jq -er .region "$CONFIG")
WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
export KUBECONFIG="$WORK/kubeconfig"
case "$CLOUD" in
  aws)
    aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"
    ;;
  gcp)
    gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$(jq -er .project_id "$CONFIG")" --internal-ip
    ;;
  azure)
    az aks get-credentials --name "$CLUSTER" --resource-group "$(jq -er .resource_group_name "$CONFIG")" --file "$KUBECONFIG" --overwrite-existing
    kubelogin convert-kubeconfig --login azurecli
    ;;
  *) echo "Unsupported cloud: $CLOUD" >&2; exit 1 ;;
esac
kubectl get nodes --request-timeout=30s

if [[ "$ACTION" == uninstall ]]; then
  test "$TARGET_ENV" = uat
  # Keep the cloud controller alive until its load balancer finalizers finish.
  releases=$(helm list --all --namespace edge --output json)
  if jq -e 'any(.[]; .name == "home-run-platform")' <<< "$releases" >/dev/null; then
    helm uninstall home-run-platform --namespace edge --wait --timeout 20m
  fi
  for entry in 'linkerd:linkerd-control-plane' 'linkerd:linkerd-crds' 'kube-system:aws-load-balancer-controller'; do
    namespace="${entry%%:*}"
    release="${entry#*:}"
    releases=$(helm list --all --namespace "$namespace" --output json)
    if jq -e --arg release "$release" 'any(.[]; .name == $release)' <<< "$releases" >/dev/null; then
      helm uninstall "$release" --namespace "$namespace" --wait --timeout 10m
    fi
  done
  exit 0
fi

test -f "$VALUES"
: "${INGRESS_HOST:?Set the public DNS hostname}"
: "${LINKERD_TRUST_ANCHORS_FILE:?Supply the Linkerd trust anchor certificate}"
: "${LINKERD_ISSUER_CERT_FILE:?Supply the signed Linkerd issuer certificate}"
: "${LINKERD_ISSUER_KEY_FILE:?Supply the Linkerd issuer private key}"
for certificate in "$LINKERD_TRUST_ANCHORS_FILE" "$LINKERD_ISSUER_CERT_FILE"; do
  openssl x509 -in "$certificate" -noout -checkend 86400
done
openssl verify -CAfile "$LINKERD_TRUST_ANCHORS_FILE" "$LINKERD_ISSUER_CERT_FILE"
openssl x509 -in "$LINKERD_ISSUER_CERT_FILE" -pubkey -noout > "$WORK/cert.pub"
openssl pkey -in "$LINKERD_ISSUER_KEY_FILE" -pubout > "$WORK/key.pub"
cmp "$WORK/cert.pub" "$WORK/key.pub"

install_gateway_api=true
if [[ "$CLOUD" == gcp ]]; then
  # GKE owns its Gateway API CRDs; do not adopt them into the Linkerd release.
  install_gateway_api=false
  kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null
fi
helm upgrade --install linkerd-crds linkerd-crds --repo https://helm.linkerd.io/edge \
  --version 2026.9.3 --namespace linkerd --create-namespace \
  --set "installGatewayAPI=$install_gateway_api" --wait --timeout 10m
helm upgrade --install linkerd-control-plane linkerd-control-plane --repo https://helm.linkerd.io/edge \
  --version 2026.9.3 --namespace linkerd --values "$ROOT/linkerd-ha.yaml" \
  --set-file identityTrustAnchorsPEM="$LINKERD_TRUST_ANCHORS_FILE" \
  --set-file identity.issuer.tls.crtPEM="$LINKERD_ISSUER_CERT_FILE" \
  --set-file identity.issuer.tls.keyPEM="$LINKERD_ISSUER_KEY_FILE" \
  --wait --timeout 15m
if [[ "$CLOUD" == aws ]]; then
  : "${AWS_ACM_CERTIFICATE_ARN:?Supply an issued ACM certificate in the cluster region}"
  helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
    --repo https://aws.github.io/eks-charts --version 3.5.0 --namespace kube-system \
    --set-string clusterName="$CLUSTER" --set-string region="$REGION" \
    --set-string vpcId="$(jq -er .vpc_id "$CONFIG")" \
    --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
    --set enableServiceMutatorWebhook=false --wait --timeout 10m
fi
kubectl create namespace edge --dry-run=client -o yaml | kubectl apply -f -
if [[ "$CLOUD" != aws ]]; then
  : "${INGRESS_TLS_CERT_FILE:?Supply the public ingress TLS certificate}"
  : "${INGRESS_TLS_KEY_FILE:?Supply the public ingress TLS key}"
  kubectl create secret tls gateway-tls --namespace edge --cert="$INGRESS_TLS_CERT_FILE" --key="$INGRESS_TLS_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
args=(--set-string "cloud=$CLOUD" --set-string "environment=$TARGET_ENV" --set-string "host=$INGRESS_HOST" --set-string "vpcCidr=$(jq -er .vpc_cidr "$CONFIG")")
if [[ "$CLOUD" == aws ]]; then
  args+=(--set-string "aws.certificateArn=$AWS_ACM_CERTIFICATE_ARN" --set-string "aws.securityGroupId=$(jq -er .alb_security_group_id "$CONFIG")")
fi
helm upgrade --install home-run-platform "$ROOT/platform" --namespace edge --values "$VALUES" "${args[@]}" --wait --timeout 15m
kubectl rollout status deployment/gateway --namespace edge --timeout=5m
if [[ "$CLOUD" == gcp ]]; then
  kubectl wait --for=condition=Programmed gateway/public --namespace edge --timeout=15m
  kubectl get gateway/public --namespace edge -o wide
else
  kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0]}' ingress/public --namespace edge --timeout=15m
  kubectl get ingress/public --namespace edge -o wide
fi
echo 'Point the configured DNS hostname at the published load balancer before testing HTTPS.'

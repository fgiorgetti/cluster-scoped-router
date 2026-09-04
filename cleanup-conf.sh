#!/usr/bin/env bash
# cleanup-conf.sh — remove previously applied kube services and router entities
# Requires: kubectl, jq

set -uo pipefail

# ─── helpers ────────────────────────────────────────────────────────────────

die() {
    echo "Error: $*" >&2
    exit 1
}

# ─── resolve cluster ─────────────────────────────────────────────────────────

cluster=$(kubectl config current-context) || die "could not determine current kubectl context"
[[ -n "$cluster" ]] || die "kubectl current-context is empty"

# ─── cleanup ─────────────────────────────────────────────────────────────────

echo "==> Cleaning up previous configuration for cluster '${cluster}'"

echo "  Deleting services labeled van-service-type=consume from all namespaces"
kubectl delete svc --all-namespaces -l van-service-type=consume || true

echo "  Deleting endpointslices labeled skupper.io/type=endpointslice from all namespaces"
kubectl delete endpointslices --all-namespaces -l 'skupper.io/type=endpointslice' || true

echo "  Deleting existing tcpListener entities"
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "    skmanage delete --type tcpListener --name ${name}"
    kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage delete --type tcpListener --name "${name}" || true
done < <(kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage query --type tcpListener 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)

echo "  Deleting existing tcpConnector entities"
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "    skmanage delete --type tcpConnector --name ${name}"
    kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage delete --type tcpConnector --name "${name}" || true
done < <(kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage query --type tcpConnector 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)

echo "  Deleting existing connector entities (role=inter-router)"
# Collect sslProfiles referenced by connectors before deletion
ssl_profiles=()
while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    ssl_profiles+=("$profile")
done < <(kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage query --type connector 2>/dev/null | jq -r '.[] | select(.role=="inter-router") | .sslProfile // empty' 2>/dev/null || true)

while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "    skmanage delete --type connector --name ${name}"
    kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage delete --type connector --name "${name}" || true
done < <(kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage query --type connector 2>/dev/null | jq -r '.[] | select(.role=="inter-router") | .name' 2>/dev/null || true)

echo "  Deleting sslProfiles used by deleted connectors"
for profile in "${ssl_profiles[@]}"; do
    echo "    skmanage delete --type sslProfile --name ${profile}"
    kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage delete --type sslProfile --name "${profile}" || true
done

echo "==> Cleanup done"

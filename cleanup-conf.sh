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

echo "  Deleting services labeled van-service-type=consume/expose from all namespaces"
kubectl delete svc --all-namespaces -l van-service-type=consume || true
kubectl delete svc --all-namespaces -l van-service-type=expose  || true

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
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "    skmanage delete --type connector --name ${name}"
    kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage delete --type connector --name "${name}" || true
done < <(kubectl -n skupper exec daemonsets/skupper-router-v3 -- skmanage query --type connector 2>/dev/null | jq -r '.[] | select(.role=="inter-router") | .name' 2>/dev/null || true)

echo "==> Cleanup done"

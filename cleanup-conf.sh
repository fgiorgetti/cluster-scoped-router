#!/usr/bin/env bash
# cleanup-conf.sh — remove previously applied kube services and router entities
# Requires: kubectl, jq

set -uo pipefail

# ─── helpers ────────────────────────────────────────────────────────────────

die() {
    echo "Error: $*" >&2
    exit 1
}

resolve_router_ns() {
    local namespaces
    mapfile -t namespaces < <(kubectl get daemonsets --all-namespaces --no-headers \
        --field-selector metadata.name=skupper-router-multi-tenant \
        -o custom-columns=":metadata.namespace" 2>/dev/null)
    case "${#namespaces[@]}" in
        0) die "No skupper-router-multi-tenant DaemonSet found in any namespace." ;;
        1) echo "${namespaces[0]}" ;;
        *)
            echo "Multiple namespaces contain skupper-router-multi-tenant. Pick one:" >&2
            select ns in "${namespaces[@]}"; do
                [[ -n "$ns" ]] && { echo "$ns"; return; }
                echo "Invalid selection; try again." >&2
            done
            ;;
    esac
}

# ─── resolve cluster ─────────────────────────────────────────────────────────

cluster=$(kubectl config current-context) || die "could not determine current kubectl context"
[[ -n "$cluster" ]] || die "kubectl current-context is empty"
cluster="${cluster//\//-}"

ROUTER_NS=$(resolve_router_ns)

# ─── cleanup ─────────────────────────────────────────────────────────────────

echo "==> Cleaning up previous configuration for cluster '${cluster}'"

echo "  Deleting services labeled van-service-type=consume from all namespaces"
kubectl delete svc --all-namespaces -l van-service-type=consume || true

echo "  Deleting endpointslices labeled skupper.io/type=endpointslice from all namespaces"
kubectl delete endpointslices --all-namespaces -l 'skupper.io/type=endpointslice' || true

echo "  Deleting existing tcpListener entities"
for pod in $(kubectl -n "${ROUTER_NS}" get pod -l app=skupper-router -o custom-columns=':metadata.name' --no-headers); do
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        echo "    skmanage delete --type tcpListener --name ${name}"
        kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage delete --type tcpListener --name "${name}" || true
    done < <(kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage query --type tcpListener 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
done
echo "  Deleting existing tcpConnector entities"
for pod in $(kubectl -n "${ROUTER_NS}" get pod -l app=skupper-router -o custom-columns=':metadata.name' --no-headers); do
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        echo "    skmanage delete --type tcpConnector --name ${name}"
        kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage delete --type tcpConnector --name "${name}" || true
    done < <(kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage query --type tcpConnector 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
done

echo "  Deleting existing connector entities (role=edge)"
# Collect sslProfiles referenced by connectors before deletion
for pod in $(kubectl -n "${ROUTER_NS}" get pod -l app=skupper-router -o custom-columns=':metadata.name' --no-headers); do
    ssl_profiles=()
    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        ssl_profiles+=("$profile")
    done < <(kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage query --type connector 2>/dev/null | jq -r '.[] | select(.role=="edge") | .sslProfile // empty' 2>/dev/null || true)

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        echo "    skmanage delete --type connector --name ${name}"
        kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage delete --type connector --name "${name}" || true
    done < <(kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage query --type connector 2>/dev/null | jq -r '.[] | select(.role=="edge") | .name' 2>/dev/null || true)

    echo "  Deleting sslProfiles used by deleted connectors"
    for profile in "${ssl_profiles[@]}"; do
        echo "    skmanage delete --type sslProfile --name ${profile}"
        kubectl -n "$ROUTER_NS" exec "pod/${pod}" -- skmanage delete --type sslProfile --name "${profile}" || true
    done
done

echo "==> Cleanup done"

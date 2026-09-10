#!/usr/bin/env bash
# sync-conf.sh — apply all kube resources and router entities for the current cluster
# Requires: kubectl

set -uo pipefail

shopt -s nullglob

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

cluster_dir="cluster/${cluster}"
[[ -d "$cluster_dir" ]] || die "cluster directory '${cluster_dir}' does not exist"

ROUTER_NS=$(resolve_router_ns)

# ─── cleanup ─────────────────────────────────────────────────────────────────

"$(dirname "$0")/cleanup-conf.sh"

# ─── kube apply ──────────────────────────────────────────────────────────────

echo "==> Applying Kubernetes resources for cluster '${cluster}'"

for yaml_file in "${cluster_dir}"/*/kube/*.yaml; do
    # extract namespace from path: cluster/<name>/<namespace>/kube/<file>.yaml
    namespace=$(echo "$yaml_file" | awk -F'/' '{print $3}')
    echo "  kubectl -n ${namespace} apply -f ${yaml_file}"
    kubectl -n "${namespace}" apply -f "${yaml_file}"
done

# ─── patch daemonset secret mounts ──────────────────────────────────────────

echo "==> Patching skupper-router-multi-tenant DaemonSet secret mounts for cluster '${cluster}'"

for secret_file in "${cluster_dir}/${ROUTER_NS}/kube"/secret_client-*.yaml; do
    secret_name=$(grep -m1 '^\s*name:' "${secret_file}" | awk '{print $2}')
    [[ -z "$secret_name" ]] && continue
    mount_path="/etc/skupper-router-certs/${secret_name}"
    echo "  mounting secret '${secret_name}' at ${mount_path}"
    kubectl -n "$ROUTER_NS" patch daemonset skupper-router-multi-tenant --type=json -p \
        "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"${secret_name}\",\"mountPath\":\"${mount_path}\"}},{\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"${secret_name}\",\"secret\":{\"secretName\":\"${secret_name}\"}}}]" || true
done

echo "  waiting for skupper-router-multi-tenant rollout to complete..."
kubectl -n "$ROUTER_NS" rollout status daemonset/skupper-router-multi-tenant

# ─── router entity apply ─────────────────────────────────────────────────────

echo "==> Applying router entities for cluster '${cluster}'"

for json_file in "${cluster_dir}/${ROUTER_NS}/router/sslProfile"/*.json; do
    echo "  skmanage create sslProfile < ${json_file}"
    for pod in $(kubectl -n "${ROUTER_NS}" get pod -l app=skupper-router -o custom-columns=':metadata.name' --no-headers); do
        cat "${json_file}" | kubectl -n "$ROUTER_NS" exec -i "pod/${pod}" -- skmanage create --type sslProfile --stdin
    done
done

for json_file in "${cluster_dir}/${ROUTER_NS}/router/connector"/*.json; do
    echo "  skmanage create connector < ${json_file}"
    for pod in $(kubectl -n "${ROUTER_NS}" get pod -l app=skupper-router -o custom-columns=':metadata.name' --no-headers); do
        cat "${json_file}" | kubectl -n "$ROUTER_NS" exec -i "pod/${pod}" -- skmanage create --type connector --stdin
    done
done

for json_file in "${cluster_dir}"/*/router/*/*.json; do
    # extract entity-type from path: cluster/<name>/<namespace>/router/<entity-type>/<file>.json
    entity_type=$(echo "$json_file" | awk -F'/' '{print $5}')
    [[ "$entity_type" == "sslProfile" || "$entity_type" == "connector" ]] && continue
    echo "  skmanage create ${entity_type} < ${json_file}"
    for pod in $(kubectl -n "${ROUTER_NS}" get pod -l app=skupper-router -o custom-columns=':metadata.name' --no-headers); do
        cat "${json_file}" | kubectl -n "$ROUTER_NS" exec -i "pod/${pod}" -- skmanage create --type "${entity_type}" --stdin
    done
done

echo "==> Done"

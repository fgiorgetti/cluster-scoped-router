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

# ─── resolve cluster ─────────────────────────────────────────────────────────

cluster=$(kubectl config current-context) || die "could not determine current kubectl context"
[[ -n "$cluster" ]] || die "kubectl current-context is empty"

cluster_dir="cluster/${cluster}"
[[ -d "$cluster_dir" ]] || die "cluster directory '${cluster_dir}' does not exist"

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

echo "==> Patching skupper-router-v3 DaemonSet secret mounts for cluster '${cluster}'"

for secret_file in "${cluster_dir}/skupper/kube"/secret_client-*.yaml; do
    secret_name=$(grep -m1 '^\s*name:' "${secret_file}" | awk '{print $2}')
    [[ -z "$secret_name" ]] && continue
    mount_path="/etc/skupper-router-certs/${secret_name}"
    echo "  mounting secret '${secret_name}' at ${mount_path}"
    kubectl -n skupper patch daemonset skupper-router-v3 --type=json -p \
        "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"${secret_name}\",\"mountPath\":\"${mount_path}\"}},{\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"${secret_name}\",\"secret\":{\"secretName\":\"${secret_name}\"}}}]" || true
done

echo "  waiting for skupper-router-v3 rollout to complete..."
kubectl -n skupper rollout status daemonset/skupper-router-v3

# ─── router entity apply ─────────────────────────────────────────────────────

echo "==> Applying router entities for cluster '${cluster}'"

for json_file in "${cluster_dir}/skupper/router/sslProfile"/*.json; do
    echo "  skmanage create sslProfile < ${json_file}"
    cat "${json_file}" | kubectl -n skupper exec -i daemonset/skupper-router-v3 -- skmanage create --type sslProfile --stdin
done

for json_file in "${cluster_dir}/skupper/router/connector"/*.json; do
    echo "  skmanage create connector < ${json_file}"
    cat "${json_file}" | kubectl -n skupper exec -i daemonset/skupper-router-v3 -- skmanage create --type connector --stdin
done

for json_file in "${cluster_dir}"/*/router/*/*.json; do
    # extract entity-type from path: cluster/<name>/<namespace>/router/<entity-type>/<file>.json
    entity_type=$(echo "$json_file" | awk -F'/' '{print $5}')
    [[ "$entity_type" == "sslProfile" || "$entity_type" == "connector" ]] && continue
    echo "  skmanage create ${entity_type} < ${json_file}"
    cat "${json_file}" | kubectl -n skupper exec -i daemonset/skupper-router-v3 -- skmanage create --type "${entity_type}" --stdin
done

echo "==> Done"

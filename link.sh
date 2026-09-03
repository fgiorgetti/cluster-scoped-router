#!/usr/bin/env bash
# link.sh — interactive dialog-based inter-cluster link creator for skupper
# Requires: dialog, kubectl, jq

set -uo pipefail

shopt -s nullglob

BACKTITLE="Skupper Inter-Cluster Link"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ─── helpers ────────────────────────────────────────────────────────────────

die() {
    dialog --backtitle "$BACKTITLE" --msgbox "Error: $*" 7 50
    clear; exit 1
}

# Run dialog with output captured to TMPFILE; returns dialog's exit code.
# Explicitly bind dialog to /dev/tty so it works inside $() subshells.
dlg() {
    dialog --backtitle "$BACKTITLE" "$@" 2>"$TMPFILE" >/dev/tty </dev/tty
}

result() { cat "$TMPFILE"; }

# ─── target cluster selection ───────────────────────────────────────────────

pick_target_cluster() {
    local current="$1"
    local menu_items=()
    local cluster_name

    for server_file in cluster/*/server.json; do
        # Extract cluster name: cluster/<name>/server.json
        cluster_name=$(echo "$server_file" | awk -F'/' '{print $2}')
        if [[ "$cluster_name" != "$current" ]]; then
            menu_items+=("$cluster_name" "Target cluster server endpoint")
        fi
    done

    if (( ${#menu_items[@]} == 0 )); then
        dlg --msgbox "No target cluster server endpoints found in cluster/*/server.json (other than current cluster '${current}')." 8 60
        return 1
    fi

    dlg --title "Select Target Cluster" \
        --menu "Choose a target cluster to link with '${current}':" 15 65 6 \
        "${menu_items[@]}" || return 1

    result
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
    for cmd in dialog kubectl jq; do
        command -v "$cmd" &>/dev/null || die "Required command '$cmd' is not installed."
    done

    local current_cluster
    current_cluster=$(kubectl config current-context 2>/dev/null) || die "Could not determine current kubectl context."
    [[ -n "$current_cluster" ]] || die "kubectl current-context is empty."

    local target_cluster
    target_cluster=$(pick_target_cluster "$current_cluster") || { clear; exit 0; }

    local target_server_file="cluster/${target_cluster}/server.json"
    [[ -f "$target_server_file" ]] || die "Target server file '${target_server_file}' not found."

    local host port
    host=$(jq -r '.host // empty' "$target_server_file" 2>/dev/null)
    port=$(jq -r '.port // empty' "$target_server_file" 2>/dev/null)

    [[ -n "$host" ]] || die "Failed to extract 'host' from ${target_server_file}."
    [[ -n "$port" ]] || die "Failed to extract 'port' from ${target_server_file}."

    local target_client_secret_file="cluster/${target_cluster}/client-secret.yaml"
    [[ -f "$target_client_secret_file" ]] || die "Target client secret file '${target_client_secret_file}' not found."

    # Paths for new resources
    local base_cluster_dir="cluster/${current_cluster}/skupper"
    local connector_dir="${base_cluster_dir}/router/connector"
    local ssl_profile_dir="${base_cluster_dir}/router/sslProfile"
    local kube_dir="${base_cluster_dir}/kube"

    mkdir -p "${connector_dir}" "${ssl_profile_dir}" "${kube_dir}" 2>/dev/null || true

    local connector_file="${connector_dir}/${target_cluster}.json"
    local ssl_profile_file="${ssl_profile_dir}/client-${target_cluster}.json"
    local kube_secret_file="${kube_dir}/secret_client-${target_cluster}.yaml"

    # 1. Generate connector JSON
    cat <<EOF > "${connector_file}"
{
  "name": "link/${target_cluster}",
  "host": "${host}",
  "port": ${port},
  "role": "inter-router",
  "sslProfile": "client-${target_cluster}"
}
EOF

    # 2. Generate sslProfile JSON
    cat <<EOF > "${ssl_profile_file}"
{
  "name": "client-${target_cluster}",
  "certFile": "/etc/skupper-router-certs/client-${target_cluster}/tls.crt",
  "privateKeyFile": "/etc/skupper-router-certs/client-${target_cluster}/tls.key",
  "caCertFile": "/etc/skupper-router-certs/client-${target_cluster}/ca.crt"
}
EOF

    # 3. Generate kube client secret manifest
    local b64_ca b64_tls_crt b64_tls_key
    # Extract ca.crt, tls.crt, tls.key from target client-secret.yaml
    b64_ca=$(grep -E '^\s*ca\.crt:' "$target_client_secret_file" | awk '{print $2}' | tr -d '\r\n')
    b64_tls_crt=$(grep -E '^\s*tls\.crt:' "$target_client_secret_file" | awk '{print $2}' | tr -d '\r\n')
    b64_tls_key=$(grep -E '^\s*tls\.key:' "$target_client_secret_file" | awk '{print $2}' | tr -d '\r\n')

    [[ -n "$b64_ca" ]] || die "Could not find ca.crt in ${target_client_secret_file}."
    [[ -n "$b64_tls_crt" ]] || die "Could not find tls.crt in ${target_client_secret_file}."
    [[ -n "$b64_tls_key" ]] || die "Could not find tls.key in ${target_client_secret_file}."

    cat <<EOF > "${kube_secret_file}"
apiVersion: v1
kind: Secret
metadata:
  name: client-${target_cluster}
type: kubernetes.io/tls
data:
  ca.crt: ${b64_ca}
  tls.crt: ${b64_tls_crt}
  tls.key: ${b64_tls_key}
EOF

    clear
    echo "────────────────────────────────────────────────────────────"
    echo " Inter-Cluster Link Configuration Created"
    echo "────────────────────────────────────────────────────────────"
    echo " Current Cluster : ${current_cluster}"
    echo " Target Cluster  : ${target_cluster}"
    echo " Host            : ${host}"
    echo " Port            : ${port}"
    echo "────────────────────────────────────────────────────────────"
    echo " Generated Files:"
    echo "  - ${connector_file}"
    echo "  - ${ssl_profile_file}"
    echo "  - ${kube_secret_file}"
    echo "────────────────────────────────────────────────────────────"
    echo ""
}

main "$@"

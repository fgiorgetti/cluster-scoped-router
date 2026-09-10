#!/usr/bin/env bash
# link.sh — interactive dialog-based inter-cluster link creator for skupper
# Requires: dialog, kubectl, jq

set -uo pipefail

shopt -s nullglob

BACKTITLE="Skupper MultiTenantSite to Backbone Link"
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

# Prompt the user for a Skupper Link YAML file path and validate it.
# Stores the validated path in the caller's variable named by $1 (nameref).
select_link_file() {
    local -n _link_file_ref=$1

    dlg --inputbox "Enter the path to the Skupper Link YAML file:" 8 60 || { clear; exit 0; }
    _link_file_ref=$(result)

    [[ -n "$_link_file_ref" ]] || die "No link file path provided."
    [[ -f "$_link_file_ref" ]] || die "File '$_link_file_ref' does not exist."

    grep -Eq '^\s*kind:\s*Secret' "$_link_file_ref" || die "File '$_link_file_ref' is missing a Secret document."
    grep -Eq '^\s*kind:\s*Link' "$_link_file_ref" || die "File '$_link_file_ref' is missing a Link document."
}

# Prompt the user to select one or more target clusters from ./cluster/<dir>/.
# Stores the selected cluster names in the caller's array variable named by $1 (nameref).
select_target_clusters() {
    local -n _clusters_ref=$1

    local -a cluster_dirs
    mapfile -t cluster_dirs < <(find ./cluster -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

    [[ ${#cluster_dirs[@]} -gt 0 ]] || die "No cluster directories found under ./cluster/."

    # Build checklist items: <tag> <description> <status>
    local -a items=()
    local dir
    for dir in "${cluster_dirs[@]}"; do
        items+=("$dir" "$dir" "off")
    done

    dlg --checklist "Select target cluster(s) for the link:" 20 60 "${#cluster_dirs[@]}" "${items[@]}" || { clear; exit 0; }

    # dialog outputs space-separated quoted tokens; read them into the array
    local raw
    raw=$(result)
    [[ -n "$raw" ]] || die "No target cluster selected."

    # eval-safe split: strip surrounding quotes added by dialog and split on whitespace
    read -ra _clusters_ref <<< "${raw//\"/}"
}

# ─── main ────────────────────────────────────────────────────────────────────

# Extract the 'edge' endpoint host and port from the Link document in link_file.
# Stores the results in the caller's variables named by $2 (host) and $3 (port) (namerefs).
extract_link_endpoint() {
    local link_file=$1
    local -n _host_ref=$2
    local -n _port_ref=$3

    # Use awk to extract the Link document: accumulate each '---'-separated block
    # and print only the one that contains 'kind: Link'.
    local link_doc
    link_doc=$(awk '
        /^---/ {
            if (block ~ /kind:[[:space:]]*Link/) { print block }
            block = ""
            next
        }
        { block = block $0 "\n" }
        END { if (block ~ /kind:[[:space:]]*Link/) { print block } }
    ' "$link_file")

    [[ -n "$link_doc" ]] || die "No Link document found in '$link_file'."

    _host_ref=$(printf '%s' "$link_doc" | yq -r '.spec.endpoints[] | select(.name == "edge") | .host')
    _port_ref=$(printf '%s' "$link_doc" | yq -r '.spec.endpoints[] | select(.name == "edge") | .port')

    [[ -n "$_host_ref" ]] || die "Could not extract edge endpoint host from '$link_file'."
    [[ -n "$_port_ref" ]] || die "Could not extract edge endpoint port from '$link_file'."
}

main() {
    for cmd in dialog kubectl jq yq; do
        command -v "$cmd" &>/dev/null || die "Required command '$cmd' is not installed."
    done

    local link_file
    select_link_file link_file

    local host port
    extract_link_endpoint "$link_file" host port

    local -a target_clusters
    select_target_clusters target_clusters

    # For each selected cluster, extract the Secret document from the link file
    # and write it to cluster/<name>/<router-namespace>/kube/secret_client-uplink.yaml
    local cluster ns namespace_file base_cluster_dir connector_dir ssl_profile_dir kube_dir secret_out
    declare -a generated_files
    for cluster in "${target_clusters[@]}"; do
        namespace_file="cluster/${cluster}/namespace"
        [[ -f "$namespace_file" ]] || die "Namespace file not found for cluster '${cluster}': ${namespace_file}"

        ns=$(tr -d '[:space:]' < "$namespace_file")
        [[ -n "$ns" ]] || die "Namespace file is empty for cluster '${cluster}': ${namespace_file}"

        base_cluster_dir="cluster/${cluster}/${ns}"
        connector_dir="${base_cluster_dir}/router/connector"
        ssl_profile_dir="${base_cluster_dir}/router/sslProfile"
        kube_dir="${base_cluster_dir}/kube"
        mkdir -p "${connector_dir}" "${ssl_profile_dir}" "${kube_dir}" || true

        secret_out="${kube_dir}/secret_client-uplink.yaml"

        # Extract the Secret document from the multi-document link file.
        yq -y 'select(.kind == "Secret") | .metadata.name = "client-uplink"' "$link_file" > "$secret_out" \
            || die "Failed to write secret for cluster '${cluster}' to '${secret_out}'."

        generated_files+=(${secret_out})
        local connector_file="${connector_dir}/uplink.json"
        local ssl_profile_file="${ssl_profile_dir}/client-uplink.json"
        generated_files+=(${connector_file})
        generated_files+=(${ssl_profile_file})

        # Generate connector JSON
        cat <<EOF > "${connector_file}"
{
  "name": "link/uplink",
  "host": "${host}",
  "port": ${port},
  "role": "edge",
  "sslProfile": "client-uplink"
}
EOF

        # Generate sslProfile JSON
        cat <<EOF > "${ssl_profile_file}"
{
  "name": "client-uplink",
  "certFile": "/etc/skupper-router-certs/client-uplink/tls.crt",
  "privateKeyFile": "/etc/skupper-router-certs/client-uplink/tls.key",
  "caCertFile": "/etc/skupper-router-certs/client-uplink/ca.crt"
}
EOF

    done

    clear
    echo "────────────────────────────────────────────────────────────"
    echo " Inter-Cluster Link Configuration Created"
    echo "────────────────────────────────────────────────────────────"
    echo " Target Clusters : ${target_clusters[@]}"
    echo " Link to Host    : ${host}:${port}"
    echo "────────────────────────────────────────────────────────────"
    echo " Generated Files:"
    for f in ${generated_files[@]}; do
        echo "  - ${f}"
    done
    echo "────────────────────────────────────────────────────────────"
    echo ""

    echo "Please run sync-conf.sh to apply changes (for each of the target clusters)"
}

main "$@"

#!/usr/bin/env bash
# install-site.sh — interactive installer for a minimum skupper-router site
# Requires: dialog, kubectl, sed, openssl
# Honors $KUBECONFIG if set; otherwise uses kubectl's default (~/.kube/config).

set -uo pipefail

BACKTITLE="Skupper Site Installer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/skupper-multi-tenant.yaml"
INTER_EDGE_PORT=45671

TMPFILE=$(mktemp)
CERT_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPFILE" "$CERT_TMPDIR"' EXIT

# ─── helpers ────────────────────────────────────────────────────────────────

die() {
    dialog --backtitle "$BACKTITLE" --msgbox "Error: $*" 7 60
    clear; exit 1
}

# Run dialog with output captured to TMPFILE; returns dialog's exit code.
dlg() {
    dialog --backtitle "$BACKTITLE" "$@" 2>"$TMPFILE" >/dev/tty </dev/tty
}

result() { cat "$TMPFILE"; }

# ─── uuid ────────────────────────────────────────────────────────────────────

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        die "Cannot generate a UUID: neither uuidgen nor /proc/sys/kernel/random/uuid is available."
    fi
}

# ─── input prompts ───────────────────────────────────────────────────────────

pick_site_name() {
    local value
    while true; do
        dlg --title "Site Name" \
            --inputbox "Enter the Site Name:" 8 55 "" || { clear; exit 0; }
        value=$(result)
        [[ -n "$value" ]] && { echo "$value"; return 0; }
        dlg --msgbox "Site Name cannot be empty. Please try again." 6 50
    done
}

# ─── namespace ───────────────────────────────────────────────────────────────

pick_namespace() {
    local value
    while true; do
        dlg --title "Namespace" \
            --inputbox "Enter the namespace to install into:" 8 55 "skupper-multi-tenant" || { clear; exit 0; }
        value=$(result)
        [[ -n "$value" ]] && { echo "$value"; return 0; }
        dlg --msgbox "Namespace cannot be empty. Please try again." 6 50
    done
}

ensure_namespace() {
    if kubectl get ns "$NAMESPACE" &>/dev/null; then
        die "Namespace '$NAMESPACE' already exists. Aborting installation."
    fi
    echo " Creating namespace '$NAMESPACE' ..."
    kubectl create ns "$NAMESPACE" \
        || die "Failed to create namespace '$NAMESPACE'."
}

# ─── cluster detection & ingress ─────────────────────────────────────────────

is_openshift() {
    kubectl api-resources --api-group=route.openshift.io -o name 2>/dev/null | grep -q "^routes"
}

# ─── tls certificates & secrets ──────────────────────────────────────────────

generate_certificates_and_secrets() {
    local host="$1"
    local cluster="$2"

    command -v openssl &>/dev/null || die "openssl is required to generate TLS certificates."

    local out_dir="cluster/${cluster}"
    mkdir -p "$out_dir"

    echo " Generating self-signed TLS certificates for host: ${host} ..."

    # 1. Generate CA
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${CERT_TMPDIR}/ca.key" \
        -out "${CERT_TMPDIR}/ca.crt" \
        -subj "/CN=skupper-router-ca" &>/dev/null \
        || die "Failed to generate CA certificate."

    # 2. Generate Server Certificate with SAN
    local san_ext
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san_ext="subjectAltName=IP:${host}"
    else
        san_ext="subjectAltName=DNS:${host}"
    fi
    echo "$san_ext" > "${CERT_TMPDIR}/san.cnf"

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${CERT_TMPDIR}/tls.key" \
        -out "${CERT_TMPDIR}/server.csr" \
        -subj "/CN=${host}" &>/dev/null \
        || die "Failed to generate server certificate CSR."

    openssl x509 -req -in "${CERT_TMPDIR}/server.csr" \
        -CA "${CERT_TMPDIR}/ca.crt" \
        -CAkey "${CERT_TMPDIR}/ca.key" \
        -CAcreateserial \
        -out "${CERT_TMPDIR}/tls.crt" \
        -days 3650 \
        -extfile "${CERT_TMPDIR}/san.cnf" &>/dev/null \
        || die "Failed to sign server certificate."

    # Encode components in base64 without wrapping lines
    local b64_ca b64_server_crt b64_server_key b64_client_crt b64_client_key
    b64_ca=$(base64 < "${CERT_TMPDIR}/ca.crt" | tr -d '\r\n')
    b64_server_crt=$(base64 < "${CERT_TMPDIR}/tls.crt" | tr -d '\r\n')
    b64_server_key=$(base64 < "${CERT_TMPDIR}/tls.key" | tr -d '\r\n')

    cat <<EOF > "${out_dir}/server-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: skupper-router-inter-edge
  namespace: ${NAMESPACE}
type: kubernetes.io/tls
data:
  ca.crt: ${b64_ca}
  tls.crt: ${b64_server_crt}
  tls.key: ${b64_server_key}
EOF

    echo " Applying server secret to namespace '${NAMESPACE}'..."
    kubectl apply -f "${out_dir}/server-secret.yaml" \
        || die "Failed to apply server secret to namespace '${NAMESPACE}'."
}

# ─── apply manifest ──────────────────────────────────────────────────────────

apply_network_policy() {
    echo " Applying default-deny NetworkPolicy to namespace '${NAMESPACE}'..."
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f - \
        || die "Failed to apply default-deny NetworkPolicy."
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: skupper-router-default-deny
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${NAMESPACE}
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: ${INTER_EDGE_PORT}
EOF
}

apply_manifest() {
    local site_name="$1"
    local uuid="$2"

    [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"

    sed \
        -e "s|___SITE_NAME___|${site_name}|g" \
        -e "s|___UUID___|${uuid}|g"           \
        "$MANIFEST" \
    | kubectl apply -n "$NAMESPACE" -f - \
        || die "kubectl apply failed."

    echo "  waiting for skupper-router-multi-tenant rollout to complete..."
    kubectl -n "$NAMESPACE" rollout status daemonset/skupper-router-multi-tenant

}

# ─── full-mesh ───────────────────────────────────────────────────────────────

hash_filter_out() {
    # returns a filtered hash, excluding key ($1) from hash ref ($2) saving into filtered hash ref ($3)
    local value=$1
    local -n items="$2"
    local -n filtered="$3"
    for key in "${!items[@]}"; do
        [ "${key}" = "${value}" ] && continue
        filtered["${key}"]="${items[${key}]}"
    done
}

full_mesh() {
    # builds a full mesh between edge routers for the daemonset
    declare -A pods
    while IFS="," read -r pod ip; do
        pods["${pod}"]="${ip}"
    done < <(kubectl -n skupper-multi-tenant get pod -l app=skupper-router -o json | jq -r '.items[] | .metadata.name + "," + .status.podIP')

    for pod in "${!pods[@]}"; do
        ip="${pods[${pod}]}"
        # first delete all existing inter-edge connectors for pod
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            echo "    skmanage delete --type connector --name ${name}"
            echo kubectl -n "$NAMESPACE" exec pod/${pod} -- skmanage delete --type connector --name "${name}" || true
        done < <(kubectl -n "$NAMESPACE" exec pod/${pod} -- skmanage query --type connector 2>/dev/null | jq -r '.[] | select(.role=="inter-edge") | .name' 2>/dev/null || true)

        declare -A targets=()
        hash_filter_out "${pod}" pods targets
        [ ${#targets[@]} -eq 0 ] && break

        # creating the mesh connector
        for target in ${targets[@]}; do
            target_ip_name="${targets[${target}]//./-}"
            echo skmanage create --type connector --name "mesh/${target}" "host=${target_ip_name}.skupper-router-mesh" "port=45671" "role=inter-edge" "sslProfile=mesh-profile"
            echo kubectl -n "$NAMESPACE" exec pod/${pod} -- \
                skmanage create --type connector --name "mesh/${target}" "host=${target_ip_name}.skupper-router-mesh" "port=45671" "role=inter-edge" "sslProfile=mesh-profile" || true
        done
    done
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
    local site_name uuid cluster

    NAMESPACE=$(pick_namespace)
    site_name=$(pick_site_name)
    uuid=$(generate_uuid)
    cluster=$(kubectl config current-context 2>/dev/null || echo "default")
    [[ -n "$cluster" ]] || cluster="default"

    [[ -d "cluster/${cluster}" ]] || mkdir -p "cluster/${cluster}"

    clear
    echo "──────────────────────────────────────────"
    echo " Skupper Site Installer"
    echo "──────────────────────────────────────────"
    echo " Cluster    : ${cluster}"
    echo " Namespace  : ${NAMESPACE}"
    echo " Site Name  : ${site_name}"
    echo " UUID       : ${uuid}"
    echo "──────────────────────────────────────────"
    echo ""

    ensure_namespace

    generate_certificates_and_secrets "*.skupper-router-mesh" "$cluster"

    apply_manifest "$site_name" "$uuid"

    apply_network_policy

    create_ssl_profile

    full_mesh

    echo "${NAMESPACE}" > "cluster/${cluster}/namespace"

    echo ""
    echo " ✓ Installation complete."
    echo " Generated artifacts:"
    echo "   - cluster/${cluster}/server-secret.yaml"
    echo "   - cluster/${cluster}/namespace"
    echo "──────────────────────────────────────────"
}

main "$@"

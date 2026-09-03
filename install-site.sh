#!/usr/bin/env bash
# install-site.sh — interactive installer for a minimum skupper-router site
# Requires: dialog, kubectl, sed, openssl
# Honors $KUBECONFIG if set; otherwise uses kubectl's default (~/.kube/config).

set -uo pipefail

BACKTITLE="Skupper Site Installer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/skupper-v3.yaml"
NAMESPACE="skupper"
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

pick_van_id() {
    local value
    while true; do
        dlg --title "VAN ID" \
            --inputbox "Enter the VAN ID:" 8 55 "" || { clear; exit 0; }
        value=$(result)
        [[ -n "$value" ]] && { echo "$value"; return 0; }
        dlg --msgbox "VAN ID cannot be empty. Please try again." 6 50
    done
}

# ─── namespace ───────────────────────────────────────────────────────────────

ensure_namespace() {
    if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
        echo " Creating namespace '$NAMESPACE' ..."
        kubectl create ns "$NAMESPACE" \
            || die "Failed to create namespace '$NAMESPACE'."
    fi
}

# ─── pre-flight check ────────────────────────────────────────────────────────

check_no_controller() {
    if kubectl get deployment skupper-controller -n "$NAMESPACE" &>/dev/null; then
        die "Namespace '$NAMESPACE' already has a Deployment named 'skupper-controller'.\nAborting installation."
    fi
}

# ─── cluster detection & ingress ─────────────────────────────────────────────

is_openshift() {
    kubectl api-resources --api-group=route.openshift.io -o name 2>/dev/null | grep -q "^routes"
}

setup_ingress() {
    ENDPOINT_HOST=""
    ENDPOINT_PORT=""

    if is_openshift; then
        echo " Detected OpenShift cluster."
        echo " Exposing skupper-router on port ${INTER_EDGE_PORT} via ClusterIP service and TLS passthrough route..."

        # Create ClusterIP service for inter-router listener
        cat <<EOF | kubectl apply -n "$NAMESPACE" -f - || die "Failed to create inter-router service on OpenShift."
apiVersion: v1
kind: Service
metadata:
  name: skupper-router-inter-router
  labels:
    app: skupper-router
spec:
  type: ClusterIP
  selector:
    app: skupper-router
  ports:
  - name: inter-router
    port: ${INTER_EDGE_PORT}
    targetPort: ${INTER_EDGE_PORT}
    protocol: TCP
EOF

        # Create Route with TLS passthrough
        cat <<EOF | kubectl apply -n "$NAMESPACE" -f - || die "Failed to create inter-router route on OpenShift."
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: skupper-router-inter-router
  labels:
    app: skupper-router
spec:
  to:
    kind: Service
    name: skupper-router-inter-router
  port:
    targetPort: ${INTER_EDGE_PORT}
  tls:
    termination: passthrough
EOF

        # Retrieve Route hostname
        echo " Waiting for route hostname..."
        for _ in {1..30}; do
            ENDPOINT_HOST=$(kubectl get route skupper-router-inter-router -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
            if [[ -z "$ENDPOINT_HOST" ]]; then
                ENDPOINT_HOST=$(kubectl get route skupper-router-inter-router -n "$NAMESPACE" -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)
            fi
            [[ -n "$ENDPOINT_HOST" ]] && break
            sleep 1
        done

        [[ -n "$ENDPOINT_HOST" ]] || die "Failed to retrieve hostname for route skupper-router-inter-router."
        ENDPOINT_PORT="443"
    else
        echo " Detected generic Kubernetes cluster."
        echo " Exposing skupper-router on port ${INTER_EDGE_PORT} via LoadBalancer service..."

        cat <<EOF | kubectl apply -n "$NAMESPACE" -f - || die "Failed to create LoadBalancer service."
apiVersion: v1
kind: Service
metadata:
  name: skupper-router-inter-router
  labels:
    app: skupper-router
spec:
  type: LoadBalancer
  selector:
    app: skupper-router
  ports:
  - name: inter-router
    port: ${INTER_EDGE_PORT}
    targetPort: ${INTER_EDGE_PORT}
    protocol: TCP
EOF

        # Retrieve LoadBalancer IP or hostname
        echo " Waiting for LoadBalancer external IP / hostname..."
        for _ in {1..30}; do
            ENDPOINT_HOST=$(kubectl get svc skupper-router-inter-router -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
            if [[ -z "$ENDPOINT_HOST" ]]; then
                ENDPOINT_HOST=$(kubectl get svc skupper-router-inter-router -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
            fi
            [[ -n "$ENDPOINT_HOST" ]] && break
            sleep 2
        done

        if [[ -z "$ENDPOINT_HOST" ]]; then
            # Fallback to first node IP or cluster IP if load balancer is pending
            ENDPOINT_HOST=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)
            [[ -z "$ENDPOINT_HOST" ]] && ENDPOINT_HOST=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
            [[ -z "$ENDPOINT_HOST" ]] && ENDPOINT_HOST="127.0.0.1"
            echo " Warning: LoadBalancer ingress IP not immediately assigned; falling back to: ${ENDPOINT_HOST}"
        fi
        ENDPOINT_PORT="${INTER_EDGE_PORT}"
    fi
}

# ─── tls certificates & secrets ──────────────────────────────────────────────

generate_certificates_and_secrets() {
    local host="$1"
    local port="$2"
    local cluster="$3"

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

    # 3. Generate Client Certificate
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${CERT_TMPDIR}/client.key" \
        -out "${CERT_TMPDIR}/client.csr" \
        -subj "/CN=skupper-router-client" &>/dev/null \
        || die "Failed to generate client certificate CSR."

    openssl x509 -req -in "${CERT_TMPDIR}/client.csr" \
        -CA "${CERT_TMPDIR}/ca.crt" \
        -CAkey "${CERT_TMPDIR}/ca.key" \
        -CAcreateserial \
        -out "${CERT_TMPDIR}/client.crt" \
        -days 3650 &>/dev/null \
        || die "Failed to sign client certificate."

    # Encode components in base64 without wrapping lines
    local b64_ca b64_server_crt b64_server_key b64_client_crt b64_client_key
    b64_ca=$(base64 < "${CERT_TMPDIR}/ca.crt" | tr -d '\r\n')
    b64_server_crt=$(base64 < "${CERT_TMPDIR}/tls.crt" | tr -d '\r\n')
    b64_server_key=$(base64 < "${CERT_TMPDIR}/tls.key" | tr -d '\r\n')
    b64_client_crt=$(base64 < "${CERT_TMPDIR}/client.crt" | tr -d '\r\n')
    b64_client_key=$(base64 < "${CERT_TMPDIR}/client.key" | tr -d '\r\n')

    # 4. Generate cluster/<name>/server-secret.yaml
    cat <<EOF > "${out_dir}/server-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: skupper-router-inter-router
  namespace: ${NAMESPACE}
type: kubernetes.io/tls
data:
  ca.crt: ${b64_ca}
  tls.crt: ${b64_server_crt}
  tls.key: ${b64_server_key}
EOF

    # 5. Generate cluster/<name>/client-secret.yaml
    cat <<EOF > "${out_dir}/client-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: skupper-router-inter-router
type: kubernetes.io/tls
data:
  ca.crt: ${b64_ca}
  tls.crt: ${b64_client_crt}
  tls.key: ${b64_client_key}
EOF

    # 6. Generate cluster/<name>/server.json
    cat <<EOF > "${out_dir}/server.json"
{
  "host": "${host}",
  "port": ${port}
}
EOF

    echo " Applying server secret to namespace '${NAMESPACE}'..."
    kubectl apply -f "${out_dir}/server-secret.yaml" \
        || die "Failed to apply server secret to namespace '${NAMESPACE}'."
}

# ─── apply manifest ──────────────────────────────────────────────────────────

apply_manifest() {
    local site_name="$1"
    local uuid="$2"
    local van_id="$3"

    [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"

    sed \
        -e "s|___SITE_NAME___|${site_name}|g" \
        -e "s|___UUID___|${uuid}|g"           \
        -e "s|___VAN_ID___|${van_id}|g"       \
        "$MANIFEST" \
    | kubectl apply -n "$NAMESPACE" -f - \
        || die "kubectl apply failed."
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
    local site_name uuid van_id cluster

    site_name=$(pick_site_name)
    van_id=$(pick_van_id)
    uuid=$(generate_uuid)
    cluster=$(kubectl config current-context 2>/dev/null || echo "default")
    [[ -n "$cluster" ]] || cluster="default"

    clear
    echo "──────────────────────────────────────────"
    echo " Skupper Site Installer"
    echo "──────────────────────────────────────────"
    echo " Cluster    : ${cluster}"
    echo " Namespace  : ${NAMESPACE}"
    echo " Site Name  : ${site_name}"
    echo " VAN ID     : ${van_id}"
    echo " UUID       : ${uuid}"
    echo "──────────────────────────────────────────"
    echo ""

    ensure_namespace
    check_no_controller

    setup_ingress

    echo " Resolved ingress endpoint : ${ENDPOINT_HOST}:${ENDPOINT_PORT}"

    generate_certificates_and_secrets "$ENDPOINT_HOST" "$ENDPOINT_PORT" "$cluster"

    apply_manifest "$site_name" "$uuid" "$van_id"

    echo ""
    echo " ✓ Installation complete."
    echo " Generated artifacts:"
    echo "   - cluster/${cluster}/server-secret.yaml"
    echo "   - cluster/${cluster}/client-secret.yaml"
    echo "   - cluster/${cluster}/server.json"
    echo "──────────────────────────────────────────"
}

main "$@"

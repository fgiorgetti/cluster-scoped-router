#!/usr/bin/env bash
# listener.sh — interactive dialog-based listener creator for skupper
# Requires: dialog, kubectl

set -uo pipefail

BACKTITLE="Skupper Listener"
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

# ─── auto-assign listener port ───────────────────────────────────────────────

next_connector_listener_port() {
    local cluster="$1"
    local -A used=()

    # Collect all "port": values from existing connector-side listener JSON files
    while IFS= read -r p; do
        [[ -n "$p" ]] && used["$p"]=1
    done < <(
        grep -roh '"port": *"[^"]*"' "cluster/${cluster}/skupper/router/tcpListener/*.json" 2>/dev/null \
            | sed 's/.*"port": *"\([^"]*\)"/\1/'
    )

    local port=1024
    while [[ -n "${used[$port]+set}" ]]; do
        (( port++ ))
    done

    echo "$port"
}

# ─── step 1: routing key ─────────────────────────────────────────────────────

pick_routing_key() {
    local -a keys=()

    # Collect routing keys live from the skupper router
    while IFS= read -r key; do
        [[ -n "$key" ]] && keys+=("$key" "")
    done < <(
        kubectl -n skupper exec daemonsets/skupper-router-v3 -- \
            skstat -a 2>/dev/null | grep ' mobile ' \
            | grep -v -E '(\.|/|\$)' | awk '{print $2}'
    )

    if (( ${#keys[@]} == 0 )); then
        dlg --msgbox "No routing keys found in the skupper router." 7 55

        dlg --yesno "Would you like to enter a routing key manually?" 7 55 \
            || return 1

        while true; do
            dlg --title "Routing Key" \
                --inputbox "Enter routing key:" 8 55 "" || return 1
            local manual_key
            manual_key=$(result)
            if [[ -z "$manual_key" ]]; then
                dlg --msgbox "Routing key cannot be empty." 6 50
                continue
            fi
            echo "$manual_key"
            return 0
        done
    fi

    dlg --title "Routing Key" \
        --menu "Select the routing key to consume:" 20 60 15 \
        "${keys[@]}" || return 1

    result
}

# ─── step 2: namespace ───────────────────────────────────────────────────────

get_namespaces() {
    kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
        || die "Cannot list namespaces (is kubectl configured?)"
}

pick_namespace() {
    local ns_list
    ns_list=$(get_namespaces)

    local -a args=()
    while IFS= read -r ns; do
        [[ -n "$ns" ]] && args+=("$ns" "")
    done <<< "$ns_list"

    (( ${#args[@]} == 0 )) && die "No namespaces found."

    dlg --title "Namespace" \
        --menu "Select the target namespace:" 20 60 15 \
        "${args[@]}" || return 1

    result
}

# ─── step 3: service name + user-facing port ─────────────────────────────────

pick_service() {
    while true; do
        dlg --title "Service" \
            --form "Enter the Kubernetes service details:" 10 60 2 \
            "Service name:" 1 1 "" 1 15 40 100 \
            "Port:"         2 1 "" 2 15 40 6 \
            || return 1

        local svc_name port
        svc_name=$(awk 'NR==1' "$TMPFILE")
        port=$(awk 'NR==2' "$TMPFILE")

        if [[ -z "$svc_name" ]]; then
            dlg --msgbox "Service name cannot be empty." 6 50
            continue
        fi

        if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
            echo "$svc_name"
            echo "$port"
            return 0
        fi

        dlg --msgbox "Invalid port '$port'. Please enter an integer between 1 and 65535." 7 55
    done
}

# ─── step 4: lookup target skupper port ──────────────────────────────────────

get_routing_key_port() {
    local cluster="$1"
    local routing_key="$2"
    local listener_file="cluster/${cluster}/skupper/router/tcpListener/${routing_key}.json"

    if [[ ! -f "$listener_file" ]]; then
        die "Listener file '$listener_file' not found for routing key '$routing_key'."
    fi

    local port
    port=$(grep -oh '"port": *"[^"]*"' "$listener_file" 2>/dev/null | sed 's/.*"port": *"\([^"]*\)"/\1/')

    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        die "Could not determine port for routing key '$routing_key' from '$listener_file'."
    fi

    echo "$port"
}

# ─── ensure skupper listener + service files exist ───────────────────────────

ensure_skupper_listener() {
    local cluster="$1"
    local routing_key="$2"

    local skupper_base="cluster/${cluster}/skupper"
    local listener_dir="${skupper_base}/router/tcpListener"
    local listener_file="${listener_dir}/${routing_key}.json"

    if [[ -f "$listener_file" ]]; then
        echo " Listener for routing key '${routing_key}' already exists — skipping."
        echo " Existing file  : ${listener_file}"
        return
    fi

    local listener_port
    listener_port=$(next_connector_listener_port "$cluster")
    mkdir -p "$listener_dir"

    cat << EOF > "${listener_file}"
{
  "name": "${routing_key}",
  "port": "${listener_port}",
  "address": "${routing_key}"
}
EOF

    echo " Listener port  : $listener_port"
    echo " Listener file  : ${listener_file}"
}

# ─── return the pod name, ip and ready condition for all router pods ─────────

pick_router_endpoints() {
    kubectl -n skupper get pod -l app=skupper-router -o json | \
        jq -r '.items[] | .metadata.namespace + " " + .metadata.name + " " + (.status | .podIP + " " + (.conditions[] | select(.type == "Ready") | .status))'
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
    local routing_key namespace svc_name svc_port target_port cluster

    routing_key=$(pick_routing_key) || { clear; exit 0; }
    namespace=$(pick_namespace)     || { clear; exit 0; }

    local svc_info
    svc_info=$(pick_service)        || { clear; exit 0; }
    svc_name=$(awk 'NR==1' <<< "$svc_info")
    svc_port=$(awk 'NR==2' <<< "$svc_info")
    router_endpoints=$(pick_router_endpoints)

    [ -z "${router_endpoints}" ] && die "No router pods found"

    clear
    cluster=$(kubectl config current-context)
    ensure_skupper_listener "$cluster" "$routing_key"
    target_port=$(get_routing_key_port "$cluster" "$routing_key")

    # Build output paths
    local kube_dir="cluster/${cluster}/${namespace}/kube"
    local endpointslice_file="${kube_dir}/endpointslice_${svc_name}.yaml"
    local service_file="${kube_dir}/service_${svc_name}.yaml"
    local external_target="port-${target_port}.skupper.svc.cluster.local"

    mkdir -p "$kube_dir"

    # Build the endpoints YAML block from router_endpoints
    local endpoints_yaml=""
    while IFS=' ' read -r ep_ns ep_name ep_ip ep_ready; do
        # Map kubectl's "True"/"False" to YAML true/false
        local ready_val="false"
        [[ "$ep_ready" == "True" ]] && ready_val="true"

        endpoints_yaml+="  - addresses:
    - \"${ep_ip}\"
    conditions:
      ready: ${ready_val}
    targetRef:
      kind: Pod
      name: ${ep_name}
      namespace: ${ep_ns}"
    done <<< "$router_endpoints"

    # Write Kubernetes EndpointSlice YAML
    cat > "$endpointslice_file" << EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${svc_name}
  labels:
    kubernetes.io/service-name: ${svc_name}
    skupper.io/type: endpointslice
addressType: IPv4
ports:
  - name: ${svc_name}-${svc_port}
    appProtocol: http
    protocol: TCP
    port: ${target_port}
endpoints:
${endpoints_yaml}
EOF

    # Write Kubernetes Service YAML
    cat > "$service_file" << EOF
apiVersion: v1
kind: Service
metadata:
  name: ${svc_name}
  namespace: ${namespace}
  labels:
    van-service-type: consume
spec:
  type: ClusterIP
  ports:
  - name: ${svc_name}-${svc_port}
    port: ${svc_port}
    targetPort: ${target_port}
    protocol: TCP
EOF

    echo "──────────────────────────────────────"
    echo " Cluster        : $cluster"
    echo " Namespace      : $namespace"
    echo " Routing key    : $routing_key"
    echo " Service name   : $svc_name"
    echo " Service port   : $svc_port"
    echo " Target port    : $target_port"
    echo " ExternalName   : $external_target"
    echo "──────────────────────────────────────"
    echo ""
    echo " Files written:"
    echo "  $service_file"
    echo "  $endpointslice_file"
    echo "──────────────────────────────────────"
    echo ""
    echo " Skupper files (created if missing above):"
    echo "  cluster/${cluster}/skupper/router/tcpListener/${routing_key}.json"
    echo "──────────────────────────────────────"
}

main "$@"

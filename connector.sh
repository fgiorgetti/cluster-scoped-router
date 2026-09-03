#!/usr/bin/env bash
# connector.sh — interactive dialog-based connector creator for skupper
# Requires: dialog, kubectl

set -uo pipefail

BACKTITLE="Skupper Connector"
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

get_namespaces() {
    kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
        || die "Cannot list namespaces (is kubectl configured?)"
}

get_targets() {
    local ns="$1"
    local items=()

    while IFS= read -r name; do
        [[ -n "$name" ]] && items+=("deployment/$name")
    done < <(kubectl get deployments -n "$ns" --no-headers \
                 -o custom-columns=":metadata.name" 2>/dev/null)

    while IFS= read -r name; do
        [[ -n "$name" ]] && items+=("statefulset/$name")
    done < <(kubectl get statefulsets -n "$ns" --no-headers \
                 -o custom-columns=":metadata.name" 2>/dev/null)

    while IFS= read -r name; do
        [[ -n "$name" ]] && items+=("pod/$name")
    done < <(kubectl get pods -n "$ns" --no-headers \
                 -o custom-columns=":metadata.name" 2>/dev/null)

    printf '%s\n' "${items[@]+"${items[@]}"}"
}

# Get pod selector labels for a target as a "key=value,..." string.
# Usage: get_label_selector <namespace> <type/name>
#   type: deployment | statefulset | pod
get_label_selector() {
    local ns="$1"
    local raw="$2"                        # e.g. "deployment/nginx"
    local kind="${raw%%/*}"               # deployment | statefulset | pod
    local name="${raw#*/}"                # nginx

    local template
    case "$kind" in
        deployment|statefulset)
            template='{{range $k,$v := .spec.template.metadata.labels}}{{$k}}={{$v}},{{end}}' ;;
        pod)
            template='{{range $k,$v := .metadata.labels}}{{$k}}={{$v}},{{end}}' ;;
        *)
            return 1 ;;
    esac

    local raw_labels
    raw_labels=$(kubectl get "$kind" "$name" -n "$ns" \
        -o go-template="$template" 2>/dev/null) || return 1

    # Strip trailing comma
    echo "${raw_labels%,}"
}

# ─── step 1: namespace ───────────────────────────────────────────────────────

pick_namespace() {
    local ns_list
    ns_list=$(get_namespaces)

    local -a args=()
    while IFS= read -r ns; do
        [[ -n "$ns" ]] && args+=("$ns" "")
    done <<< "$ns_list"

    (( ${#args[@]} == 0 )) && die "No namespaces found."

    dlg --title "Namespace" \
        --menu "Select a namespace:" 20 60 15 \
        "${args[@]}" || return 1

    result
}

# ─── step 2: target (reloads when namespace changes) ────────────────────────

pick_target() {
    local ns="$1"
    local -a args=()

    while IFS= read -r t; do
        [[ -n "$t" ]] && args+=("$t" "")
    done < <(get_targets "$ns")

    if (( ${#args[@]} == 0 )); then
        dlg --msgbox \
            "No deployments, statefulsets or pods found in namespace '$ns'.\nPlease choose a different namespace." \
            8 60
        return 1   # signal caller to re-pick namespace
    fi

    dlg --title "Target  (namespace: $ns)" \
        --menu "Select a target:" 20 70 15 \
        "${args[@]}" || return 1

    result
}

# ─── step 3: port ────────────────────────────────────────────────────────────

pick_port() {
    while true; do
        dlg --title "Port" \
            --inputbox "Enter the port number (1–65535):" 8 50 "" || return 1

        local port
        port=$(result)
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
            echo "$port"
            return 0
        fi
        dlg --msgbox "Invalid port '$port'. Please enter an integer between 1 and 65535." 7 55
    done
}

# ─── step 4: routing key ─────────────────────────────────────────────────────

pick_routing_key() {
    dlg --title "Routing Key" \
        --inputbox "Enter the routing key:" 8 50 "" || return 1
    result
}

# Get pod→IP map for all pods matching label_selector in namespace.
# Prints one "pod_name=ip" pair per line.
get_pod_ips() {
    local ns="$1"
    local selector="$2"
    kubectl get pods -n "$ns" -l "$selector" \
        -o go-template='{{range .items}}{{.metadata.name}}={{.status.podIP}}{{"\n"}}{{end}}' \
        2>/dev/null
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
    local namespace target label_selector port routing_key

    # Namespace + Target loop — if a namespace has no targets, loop back to namespace
    while true; do
        namespace=$(pick_namespace) || { clear; exit 0; }

        target=$(pick_target "$namespace") && break
        # pick_target returned 1: either no resources (user saw msgbox) or Cancel
        # In both cases, loop back to namespace selection
    done

    label_selector=$(get_label_selector "$namespace" "$target") \
        || die "Could not retrieve labels for $target in namespace $namespace."

    port=$(pick_port)            || { clear; exit 0; }
    routing_key=$(pick_routing_key) || { clear; exit 0; }

    clear
    cluster=$(kubectl config current-context)
    echo "──────────────────────────────────────"
    echo " Cluster        : $cluster"
    echo " Namespace      : $namespace"
    echo " Target         : $target"
    echo " Label selector : $label_selector"
    echo " Port           : $port"
    echo " Routing key    : $routing_key"
    echo "──────────────────────────────────────"
    echo ""

    # Build pod→IP map
    declare -A pod_ips
    while IFS='=' read -r pod ip; do
        [[ -n "$pod" ]] && pod_ips["$pod"]="$ip"
    done < <(get_pod_ips "$namespace" "$label_selector")

    echo " Pod IPs (selector: $label_selector)"
    echo "──────────────────────────────────────"
    if (( ${#pod_ips[@]} == 0 )); then
        echo " (no pods found)"
    else
        base_path="cluster/${cluster}/${namespace}"
        connector_path="${base_path}/router/tcpConnector"
        mkdir -p "${connector_path}" 2>/dev/null || true
        rm -f "${connector_path}/${pod}_*.json" 2>/dev/null || true
        for pod in "${!pod_ips[@]}"; do
            printf "  %-45s %s\n" "$pod" "${pod_ips[$pod]}"
        cat << EOF > "${connector_path}/${pod}_${pod_ips[$pod]}.json"
{
  "name": "connector/${pod}@${pod_ips[$pod]}",
  "host": "${pod_ips[$pod]}",
  "port": "${port}",
  "address": "${routing_key}"
}
EOF
        done

    fi
    echo "──────────────────────────────────────"

}

main "$@"

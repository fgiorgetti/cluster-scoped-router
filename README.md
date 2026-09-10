# cluster-scoped-router

Scripts to deploy and operate a cluster-scoped skupper-router site without the
Skupper controller. Each script is interactive (dialog-based TUI) and operates
against the cluster pointed to by the current `kubectl` context.

Generated configuration is written under `cluster/<context-name>/` and applied
to the live cluster by `sync-conf.sh`.

---

## Prerequisites

### Tools

| Tool | Used by |
|---|---|
| `dialog` | `install-site.sh`, `link.sh`, `connector.sh`, `listener.sh` |
| `kubectl` | all scripts |
| `jq` | `cleanup-conf.sh`, `listener.sh` |
| `yq` | `link.sh` |
| `openssl` | `install-site.sh` |

### Repository file

`skupper-multi-tenant.yaml` must be present in the repository root. `install-site.sh`
uses it as the router manifest template.

### Cluster access

Set `KUBECONFIG` (or rely on `~/.kube/config`) so that `kubectl config
current-context` returns the correct cluster name before running any script.
The context name is also used as the directory name under `cluster/`.

---

## Scripts

### `install-site.sh`

Installs the skupper-router into a chosen namespace as a DaemonSet and sets up
intra-cluster TLS.

**Interactive prompts**

| Prompt | Description |
|---|---|
| Namespace | Namespace to install into (default: `skupper-multi-tenant`); must not already exist |
| Site Name | Arbitrary label for this site |

**What it does**

1. Prompts for a namespace; aborts if it already exists, otherwise creates it.
2. Generates a self-signed CA, server certificate, and client certificate with
   `openssl` using `*.skupper-router-mesh` as the TLS hostname.
3. Applies the server TLS secret to the chosen namespace.
4. Substitutes site name and UUID into `skupper-multi-tenant.yaml` and applies it.
5. Applies a default-deny `NetworkPolicy` (`skupper-router-default-deny`) to
   the namespace. It allows ingress only from within the namespace itself and
   from any IP on the inter-edge port (45671).
6. Writes the chosen namespace name to `cluster/<context>/namespace`.

**Generated files**

```
cluster/<context>/
├── server-secret.yaml   # server TLS secret (applied to the cluster)
├── client-secret.yaml   # client TLS secret (shared with other clusters via link.sh)
├── server.json          # inter-edge host and port
└── namespace            # the namespace chosen during installation
```

---

### `link.sh`

Links one or more local clusters to a backbone cluster by reading a Skupper
Link YAML file (exported from the backbone) and writing the corresponding
connector and SSL profile configuration under each target cluster's directory.

**Requires**
- A Skupper Link YAML file (multi-document containing a `Secret` and a `Link`
  resource) exported from the backbone cluster.
- `install-site.sh` must have been run on every target cluster so that
  `cluster/<target>/namespace` exists.

**Interactive prompts**

| Prompt | Description |
|---|---|
| Link YAML path | Path to the multi-document Skupper Link YAML file |
| Target cluster(s) | Checklist of available `cluster/*/` directories to link |

**What it does**

1. Reads the `Link` document to extract the `edge` endpoint host and port using
   `yq`.
2. For each selected target cluster, reads its `cluster/<target>/namespace` file
   to determine the router namespace.
3. Writes an `uplink` connector JSON, an SSL profile JSON, and the client secret
   YAML under each target cluster's directory.

**Generated files** (per selected target cluster)

```
cluster/<target>/<router-ns>/
├── router/connector/uplink.json          # inter-edge connector to the backbone
├── router/sslProfile/client-uplink.json  # SSL profile referencing the client cert
└── kube/secret_client-uplink.yaml        # Kubernetes Secret with the client cert
```

Run `sync-conf.sh` on each target cluster afterwards to apply these files.

---

### `connector.sh`

Exposes a workload running on the current cluster into the VAN under a routing
key.

**Interactive prompts**

| Prompt | Description |
|---|---|
| Namespace | Namespace where the workload runs |
| Target | Deployment, StatefulSet, or Pod to expose |
| Port | Destination port on the pod (1–65535) |
| Routing key | Address used to identify this service in the VAN |

**Generated files**

One file per matching pod:

```
cluster/<context>/<namespace>/router/tcpConnector/<pod>_<pod-ip>.json
```

Each file contains the connector name, pod IP, port, and routing key address.

Run `sync-conf.sh` afterwards to apply these files to the live router.

---

### `listener.sh`

Detects routing keys available in the VAN and creates a Kubernetes Service and
EndpointSlice on the current cluster so that workloads can consume the remote
service.

**Requires** that the router is running (queries it live via `skstat`). The
router namespace is auto-detected by scanning all namespaces for a
`skupper-router-v3` DaemonSet; if multiple are found, a selection menu is
presented.

**Interactive prompts**

| Prompt | Description |
|---|---|
| Router namespace | Shown only when multiple `skupper-router-v3` DaemonSets are found |
| Routing key | Selected from live router data or entered manually |
| Namespace | Namespace that will receive the new Service |
| Service name | Name for the Kubernetes Service |
| Service port | Port exposed by the Service (1–65535) |

**Generated files**

```
cluster/<context>/<router-ns>/router/tcpListener/<routing-key>.json
cluster/<context>/<namespace>/kube/service_<service>.yaml
cluster/<context>/<namespace>/kube/endpointslice_<service>.yaml
cluster/<context>/<router-ns>/kube/networkpolicy_skupper-router-<namespace>-<service>.yaml
```

The listener port is allocated automatically starting from 1024, reusing an
existing file if one already exists for the routing key.

A per-listener `NetworkPolicy` is also generated in the router namespace. It
allows ingress to the router pods from the consuming namespace on the allocated
listener port only.

Run `sync-conf.sh` afterwards to apply these files to the live cluster and
router.

---

### `sync-conf.sh`

Applies all configuration generated by `link.sh`, `connector.sh`, and
`listener.sh` to the live cluster and router.

The router namespace is auto-detected by scanning all namespaces for a
`skupper-router-v3` DaemonSet; if multiple are found, a plain terminal `select`
prompt is shown.

**What it does (in order)**

1. Calls `cleanup-conf.sh` to remove all previously applied router entities and
   labeled Kubernetes resources.
2. Applies every `cluster/<context>/*/kube/*.yaml` manifest with `kubectl`.
3. Patches the `skupper-router-v3` DaemonSet to mount any new client-certificate
   Secrets and waits for the rollout to complete.
4. Applies SSL profiles, inter-edge connectors, and all other router entities
   (tcpConnector, tcpListener, …) via `skmanage`.

**No interactive prompts** (beyond the namespace selection if multiple router
namespaces are found). Uses the current `kubectl` context.

> **Note:** `sync-conf.sh` performs a full re-apply on every run — it always
> cleans up first and then reapplies from the files under `cluster/<context>/`.
> Re-running it after any change to the generated files is safe and idempotent.

---

### `cleanup-conf.sh`

Removes all previously applied consumed-service resources and router entities
from the live cluster. Called automatically by `sync-conf.sh`, but can also be
run standalone.

The router namespace is auto-detected by scanning all namespaces for a
`skupper-router-v3` DaemonSet; if multiple are found, a plain terminal `select`
prompt is shown.

**What it deletes**

| Resource | Selector |
|---|---|
| Kubernetes Services (all namespaces) | `van-service-type=consume` |
| Kubernetes EndpointSlices (all namespaces) | `skupper.io/type=endpointslice` |
| Router `tcpListener` entities | all |
| Router `tcpConnector` entities | all |
| Router inter-edge `connector` entities | those with `role=edge` |
| Router `sslProfile` entities | those referenced by the deleted connectors |

**No interactive prompts** (beyond the namespace selection if multiple router
namespaces are found). Uses the current `kubectl` context.

> **Note:** `cleanup-conf.sh` does **not** delete the router namespace, the
> router DaemonSet, or the `cluster/` directory. Only live applied resources are
> removed.

---

## Typical end-to-end workflow

Run the following steps in order. Steps 1 and 2 must be completed on **every
tenant cluster** in the VAN. Steps 3–5 are per-cluster and per-workload.

```
1. install-site.sh   — on each cluster: deploy the router and generate certs
2. link.sh           — on each cluster: generate connector config toward the
                       backbone (provide the backbone's exported Link YAML)
3. connector.sh      — on the cluster that exposes a workload
4. listener.sh       — on the cluster that consumes the workload
5. sync-conf.sh      — on each cluster: apply all generated config to the
                       live router (re-run after any change to steps 2–4)
```

---

## Start from scratch

To tear down a site completely and remove all generated configuration:

```bash
kubectl delete ns <router-namespace>
rm -rf cluster/
```

This deletes the router DaemonSet and all associated Kubernetes resources, and
removes the entire local `cluster/` directory including certificates and
generated JSON/YAML files.

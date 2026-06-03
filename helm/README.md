# Ursula Helm Chart

Deploy a static-membership 3-node Ursula cluster on Kubernetes.

## Prerequisites

- Kubernetes 1.25+
- Helm 3.12+
- A container image for Ursula (e.g. `ghcr.io/tonbo-io/ursula:latest`)

## Quick Start

```bash
# Add your image and S3 settings
helm install ursula ./helm \
  --namespace ursula --create-namespace \
  --set image.repository=ghcr.io/tonbo-io/ursula \
  --set image.tag=0.1.3 \
  --set coldStorage.s3.bucket=my-ursula-bucket \
  --set coldStorage.s3.region=us-east-1 \
  --set coldStorage.s3.root=ursula-prod-202606 \
  --set coldStorage.s3.accessKeyId=$AWS_ACCESS_KEY_ID \
  --set coldStorage.s3.secretAccessKey=$AWS_SECRET_ACCESS_KEY
```

### Local / Minimal 3-Node Cluster

For a resource-constrained local Kubernetes environment, use `helm/values-local.yaml`:

```bash
docker build -t ursula:local .
helm install ursula ./helm \
  --namespace ursula --create-namespace \
  -f helm/values-local.yaml
```

This keeps `replicaCount: 3`, requests three `1Gi` PVCs, lowers CPU/memory requests and limits, and uses the in-memory cold-store backend so no S3 bucket is required for local smoke testing.

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of Ursula nodes (Raft voters) | `3` |
| `image.repository` | Container image | `ghcr.io/tonbo-io/ursula` |
| `image.tag` | Image tag | `""` (falls back to `appVersion`) |
| `imagePullSecrets` | Image pull secrets | `[]` |
| `podAnnotations` | Extra annotations for pods | `{}` |
| `podSecurityContext` | Security context for the pod | `{}` |
| `securityContext` | Security context for containers | `{}` |
| `service.type` | Service type for external access | `ClusterIP` |
| `service.port` | Service port (must match port in `ursula.listen`) | `4437` |
| `persistence.enabled` | Enable PVC for raft log dir | `true` |
| `persistence.size` | PVC size | `100Gi` |
| `persistence.storageClass` | StorageClass name | `""` |
| `persistence.retain` | Keep PVCs on `helm uninstall` | `true` |
| `persistence.annotations` | Extra annotations on each PVC | `{}` |
| `ursula.listen` | Ursula listen address | `"0.0.0.0:4437"` |
| `ursula.coreCount` | `--core-count` | `16` |
| `ursula.raftGroupCount` | `--raft-group-count` | `256` |
| `ursula.raftLogDir` | Raft log directory | `"/var/lib/ursula/raft"` |
| `coldStorage.backend` | Cold backend (`s3`, `memory`, or `none`) | `s3` |
| `coldStorage.s3.bucket` | S3 bucket name | `""` |
| `coldStorage.s3.region` | S3 region | `""` |
| `coldStorage.s3.root` | Cold root prefix | `""` |
| `coldStorage.s3.endpoint` | Custom S3 endpoint | `""` |
| `coldStorage.s3.accessKeyId` | S3 access key (optional, uses IRSA/EC2 role if empty) | `""` |
| `coldStorage.s3.secretAccessKey` | S3 secret key (optional) | `""` |
| `nodeSelector` | Node selector for pod scheduling | `{}` |
| `tolerations` | Tolerations for pod scheduling | `[]` |
| `affinity` | Affinity rules for pod scheduling | `{}` |
| `ingress.enabled` | Enable ingress for HTTP API access | `false` |
| `ingress.className` | Ingress controller class name | `""` |
| `ingress.annotations` | Ingress annotations | `{}` |
| `ingress.hosts` | Ingress host rules | `[{host: "", paths: [{path: /, pathType: Prefix}]}]` |
| `ingress.tls` | Ingress TLS configuration | `[]` |

## How It Works

- **StatefulSet** with `OrderedReady` guarantees pods start sequentially (`ursula-0`, then `ursula-1`, then `ursula-2`).
- **Headless Service** (`ursula-peer`) gives each pod a stable DNS name:
  - `ursula-0.ursula-peer`
  - `ursula-1.ursula-peer`
  - `ursula-2.ursula-peer`
- **Init container** derives `node_id` from the pod's StatefulSet ordinal and writes `/etc/ursula/cluster.json`.
- **Node 0** carries `init_membership_per_group: true`; nodes 1 and 2 use `false`. Because the PVC per pod is persisted, the flag is only meaningful on a fresh cluster start; restarts ignore it.
- **Raft traffic** and **HTTP traffic** share port `4437`.

## PVC Data Protection

Each pod gets its own PVC that stores Raft logs and cluster membership state.
**Losing a PVC means losing that node's persistent state.**

By default `persistence.retain: true` sets `helm.sh/resource-policy: keep` on every
PVC so that `helm uninstall` **does not delete them**.  The PVCs remain in the
cluster and will be re-attached if you reinstall the chart with the same name.

If you intentionally want Helm to delete PVCs on uninstall (e.g. for a throw-away
dev cluster), set:

```yaml
persistence:
  retain: false
```

> ⚠️  Only do this in development. Production clusters should always retain PVCs
> or back them up via a CSI snapshot tool.

## Verify the Cluster

Forward a node port or run a verification job:

```bash
kubectl port-forward pod/ursula-0 4437:4437

curl -s http://localhost:4437/__ursula/metrics | jq '.raft_groups | length'
```

Or build a cluster manifest for `ursulactl` using the headless service DNS names.

# Developer Sandbox overlay

```bash
oc login --token=... --server=https://api.sandbox-....openshiftapps.com:6443
./deploy.sh -o overlays/sandbox -E OPENROUTER_API_KEY
```

`-E` prompts without echoing. Use `-e KEY=VALUE` for the inline form, or omit
both to deploy without any provider keys — the dashboard runs fine without
them, just with AI features off.

Deploys into whatever namespace `oc project -q` returns. Nothing here creates,
switches, or references a namespace by name.

## What's different from the SNO overlay

| | SNO | Sandbox |
|---|---|---|
| Ollama | GPU-backed, in-cluster | Not deployed — no GPU, no RAM |
| AIS relay | Running | `replicas: 0` |
| NetworkPolicies | Applied | Removed |
| App memory limit | 2Gi | 1Gi |
| Build memory limit | 8Gi | 3Gi |
| Redis PVC | 2Gi | 1Gi |

Namespace total at rest: **~1.3Gi / 860m CPU**, which leaves room for the build
pod inside the Sandbox quota.

## The build fits

Measured, not predicted: the frontend build completes in about **5 minutes**
inside the Sandbox quota (3Gi limit, `--max-old-space-size=2560`). I had
expected it to OOM on the Vite step and it does not. The relay build takes
about 1 minute.

Watch it with:

```bash
oc logs -f bc/worldmonitor
```

### Optional: build elsewhere, deploy the image

Still useful if you want to iterate faster or keep a versioned image in Quay,
but no longer necessary.

This is the reliable path and honestly the better one for Sandbox regardless —
it turns a 20-minute in-cluster build into a 60-second image pull.

```bash
# On your Mac (or in GitHub Actions)
podman build --platform linux/amd64 -f Containerfile.ocp \
  -t quay.io/ryan_nix/worldmonitor:latest .
podman push quay.io/ryan_nix/worldmonitor:latest
```

Then skip the BuildConfigs entirely:

```bash
oc delete bc/worldmonitor bc/worldmonitor-ais-relay --ignore-not-found
oc set image deploy/worldmonitor \
  worldmonitor=quay.io/ryan_nix/worldmonitor:latest
```

Note `--platform linux/amd64` — Sandbox nodes are x86, your M5 is arm64, and
Podman will happily build the wrong architecture without complaint. The pod
will then `CrashLoopBackOff` with an `exec format error`, which is a confusing
symptom for an obvious cause.

## Image references

Deployments carry an `image.openshift.io/triggers` annotation rather than a
bare ImageStream tag:

```yaml
image.openshift.io/triggers: >-
  [{"from":{"kind":"ImageStreamTag","name":"worldmonitor:latest"},
    "fieldPath":"spec.template.spec.containers[?(@.name==\"worldmonitor\")].image"}]
```

An ImageStream's `lookupPolicy.local: true` is **not** honored for Deployments
the way it is for DeploymentConfigs. With a bare `worldmonitor:latest`, the
kubelet treats it as a Docker Hub reference:

```
Failed to pull image "worldmonitor:latest":
docker.io/library/worldmonitor:latest: requested access to the resource is denied
```

The trigger annotation makes OpenShift's image-trigger controller resolve the
tag to the fully-qualified internal registry path and write it into the
container spec — in whatever namespace the manifests land in. It also
redeploys automatically when a rebuild pushes a new image to the tag, which
the bare-tag form did not do.

## Bare service names

Cross-service URLs are bare names (`http://redis-rest`, `http://ais-relay:3004`)
rather than FQDNs. They resolve through the pod's DNS search domain, which
always includes the current namespace. That's what makes these manifests
portable across namespaces without templating.

## Switching overlays on an existing namespace

PVC storage requests are immutable downward. If you already deployed the SNO
overlay (2Gi Redis PVC) and then switch to sandbox (1Gi), `oc apply` fails:

```
The PersistentVolumeClaim "redis-data" is invalid:
spec.resources.requests.storage: Forbidden: field can not be less than status.capacity
```

`deploy.sh` now catches this before applying. Redis is a cache, so recreating
it costs nothing:

```bash
oc delete deploy/redis --ignore-not-found
oc delete pvc redis-data
./deploy.sh -o overlays/sandbox
```

Delete the Deployment first — otherwise the PVC hangs in `Terminating` on the
pvc-protection finalizer while a pod still mounts it.

Alternatively, drop the `PersistentVolumeClaim` block from
`patch-resources.yaml` and keep the 2Gi volume. Against the 15Gi Sandbox budget
that is not a meaningful difference, especially if you end up deploying a
prebuilt image from Quay instead of building in-cluster.

You may also see this on a re-apply:

```
Warning: resource imagestreams/worldmonitor is missing the
kubectl.kubernetes.io/last-applied-configuration annotation
```

That is benign — it means the ImageStream was first created by something other
than `oc apply` (an `oc new-app` or `start-build`). It self-heals on the first
apply and will not recur.

## Sandbox lifecycle

Namespaces sleep after 12 hours idle and are reclaimed after 30 days. The Redis
PVC survives a sleep but not a reclaim. Nothing here holds state you'd miss —
Redis is a cache and rebuilds itself from the feeds.

## What you actually get without API keys

The dashboard runs with zero keys set; features degrade rather than break. With
nothing configured you get the map, the feed aggregation, and the UI shell. The
AI-synthesized briefs need `GROQ_API_KEY` (free tier, 14,400 req/day) which is
the single highest-value key to set. Maritime tracking needs the relay running
plus `AISSTREAM_API_KEY`.

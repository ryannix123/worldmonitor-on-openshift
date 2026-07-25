# World Monitor on OpenShift

A Red Hat–based container build and OpenShift deployment for
[koala73/worldmonitor](https://github.com/koala73/worldmonitor) — a real-time
global intelligence dashboard. This repo does two things:

1. **Builds** a UBI 10 image nightly and publishes it to Quay, with SBOM and
   vulnerability scanning.
2. **Deploys** it to OpenShift (Developer Sandbox or Single Node OpenShift) via
   Kustomize overlays.

The upstream app runs the same feed-aggregation engine everywhere; this repo
repackages it on Red Hat's supported base images and wires it for a
`restricted-v2` cluster.

## Layout

```
.github/workflows/   Nightly multi-arch build + weekly upstream-sync PR
ci/                  Scan-summary helper for the build
containers/          Containerfile.ubi10 + entrypoint (the image)
upstream.env         Pinned upstream commit SHA

base/                Kustomize base: 4 Deployments, Route, NetworkPolicy
addons/builds/       BuildConfigs + ImageStreams (in-cluster build path only)
overlays/
  sandbox/           Developer Sandbox, builds in-cluster
  sandbox-quay/      Developer Sandbox, pulls the prebuilt Quay image
  sno/               Single Node OpenShift, GPU Ollama for local LLM
deploy.sh            One-shot deploy: ./deploy.sh -o <overlay> -E OPENROUTER_API_KEY
podman/              Apple Silicon local-run path
```

## Two ways to get the image onto a cluster

**Prebuilt from Quay (recommended for demos).** CI has already built it; the
overlay just pulls it. Fastest, and the same artifact every time.

```bash
oc login --token=... --server=https://api.sandbox-....openshiftapps.com:6443
./deploy.sh -o overlays/sandbox-quay -E OPENROUTER_API_KEY
```

**Build in-cluster.** No external registry needed; OpenShift builds from source
in ~5 minutes. Useful on SNO or when you want everything self-contained.

```bash
./deploy.sh -o overlays/sandbox -E OPENROUTER_API_KEY   # or overlays/sno
```

`-E` prompts for the key without echoing. Use `-e KEY=VALUE` for the inline
form, or omit both to deploy without AI features. See `overlays/*/README.md` for
per-target detail.

## The image

`containers/Containerfile.ubi10` rebuilds upstream's Alpine image on
`ubi10/ubi-minimal` + `nodejs24`, replaces supervisord with a shell entrypoint,
and supports OpenShift's arbitrary UID. `.nvmrc` pins Node 24 and `ubi10/nodejs-24`
is GA, so there was no version compromise.

It stays a **single container** deliberately: nginx and the Node sidecar share a
per-start random `LOCAL_API_TOKEN`, and splitting them would force that into a
long-lived Secret. See `containers/` and the note in the CI section below.

### Why no supervisord / s6 / tini

Two processes, one of which exists only to serve static files and proxy `/api/`.
The entrypoint runs them as shell-managed children: `wait -n` exits with
whichever dies first, SIGTERM is forwarded to both. Note that `exec nginx` as
PID 1 was tried and rejected — it discards the trap and orphans the sidecar on
shutdown. The shell stays PID 1 for correct signal handling.

## CI

Nightly at 07:00 UTC (02:00 CDT), plus on push and manual dispatch:

- Resolves one upstream SHA for the whole run, so amd64 and arm64 build
  identical source
- Builds both arches, smoke-tests amd64 (health endpoint, SPA fallback,
  non-root UID), assembles a manifest list
- Syft SBOM + Grype scan, `--fail-on critical` only, results in the run summary
- Builds the relay image the same way (`build-relay` job,
  `Containerfile.ubi10-relay`)
- Pushes both `<sha>` and `latest` to `quay.io/ryan_nix/worldmonitor-openshift`
  and `quay.io/ryan_nix/worldmonitor-ais-relay`

`upstream-sync.yml` opens a bump PR every Monday, since upstream ships from
`main` and stopped tagging ~5 months ago. It flags changes to build-relevant
files so a bump is reviewed, not blindly merged.

### CI secrets

| Secret | Purpose |
|---|---|
| `QUAY_USERNAME` | Quay robot account, e.g. `ryan_nix+worldmonitor_ci` |
| `QUAY_PASSWORD` | That robot's token (needs Write on the repo) |

## Wiring Claude

The app has no Anthropic provider — its LLM layer speaks OpenAI-compatible,
`groq`, `openrouter`, or `ollama`. OpenRouter is the route to Claude, and the
overlays set the model routing. Before relying on it, run
`scripts/verify-openrouter.sh` (in the deploy bundle) to confirm the app's
forced provider-routing constant doesn't exclude Anthropic models. See any
overlay's notes for the profile/model detail.

## Cost note

Upstream caps AviationStack spend but has no LLM ceiling, and the seeders run on
cron across 500+ feeds. The overlays enable `USAGE_TELEMETRY` and leave the
fan-out pipelines (`AI_DIGEST_ENABLED`, `BRIEF_COMPOSE_ENABLED`) off. Prepay a
small OpenRouter balance and enable pipelines one at a time.

## Licensing

Upstream is **AGPL-3.0-only**. These build and deploy files are separate work
but don't change the license of what they package. Self-hosting is clean;
network-facing modified deployments carry the source-availability obligation.
Settle that before this becomes a customer-facing asset.

## On the CVE story

The pipeline runs `--fail-on critical` and means it. Two things happened worth
recording, because the *reasoning* matters more than the green checkmark.

**tar (CVE-2026-59873).** The relay build flagged a CVSS 9.2 in transitively
pulled `node-tar` 7.5.15 — a decompression/parse DoS. First instinct was to
force-patch it via an npm `overrides` bump to 7.5.19. That turned out to be the
wrong call twice over: npm's `overrides` is documented-unreliable for transitive
deps (it silently failed to apply across two attempts), and more importantly, a
version bump was solving the wrong problem.

The relay is a network gateway — AIS over WebSocket, OpenSky over REST, Telegram
over MTProto, RSS/JSON proxying. **It never extracts tar archives.** The
vulnerable code path is unreachable at runtime. So the honest engineering answer
isn't to fight npm into bumping a dependency the relay doesn't exploit; it's to
assess it as **not-affected** and document why. That assessment lives in
`containers/relay.openvex.json` (an OpenVEX statement) and is applied at scan
time via `.grype.yaml` using justification `vulnerable_code_not_in_execute_path`.

This is a stronger posture than a version bump: it scales (you can't force-patch
every transitive CVE forever), and it's auditable (the claim and its
justification are written down, not hidden in a lockfile diff).

Note the `.grype.yaml` ignore rule rather than `grype --vex`: Grype has a known
issue (anchore/grype#1639) where `--vex` is dropped when `--fail-on` is set. The
ignore rule is applied before the threshold check, so it actually works.

**The gate stays honest.** `--fail-on critical` is unchanged. The tar exception
is one documented, justified not-affected assessment — not a lowered bar. Any
*new* Critical, or one in code the relay actually reaches, still fails the build.

### Scope caveat

Grype scans OS and package metadata, not reachability. A clean scan means no
*known* CVEs in the dependency versions present (minus the documented VEX
exception), not that the application is free of vulnerabilities. For a claim
about application dependencies specifically, add `npm audit --production`.


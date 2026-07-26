<p align="center">
  <img src="docs/assets/banner.svg" alt="World Monitor on OpenShift" width="100%">
</p>

<p align="center">
  <a href="https://github.com/ryannix123/worldmonitor-on-openshift/actions/workflows/build.yml">
    <img src="https://github.com/ryannix123/worldmonitor-on-openshift/actions/workflows/build.yml/badge.svg" alt="Build status"></a>
  <img src="https://img.shields.io/badge/base-UBI%2010-EE0000?logo=redhat&logoColor=white" alt="UBI 10">
  <img src="https://img.shields.io/badge/platform-OpenShift-EE0000?logo=redhatopenshift&logoColor=white" alt="OpenShift">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2dd4bf" alt="Multi-arch">
  <img src="https://img.shields.io/badge/SBOM-SPDX-2dd4bf" alt="SBOM SPDX">
  <img src="https://img.shields.io/badge/scan-Grype-blueviolet" alt="Grype scanned">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-informational" alt="AGPL-3.0">
</p>

# World Monitor on OpenShift

Run a live, real-time global intelligence platform on your own cluster —
built on Red Hat UBI, published through a security-scanned pipeline, and
deployed with a single command.

[World Monitor](https://github.com/koala73/worldmonitor) turns public data —
markets, trade, conflict, energy, infrastructure, aviation, maritime, and 500+
news feeds — into a live operating picture of the world. A dark map, live
tickers, chokepoint analysis, vessel and flight tracking, AI-assisted briefs.
It's the kind of dashboard people reach for "open-source Palantir" to describe,
though [its author pushes back on that](https://www.worldmonitor.app/blog/posts/worldmonitor-is-not-palantir/):
Palantir makes *your institution's private data* operational; World Monitor
assembles *the public world's data* and shows its own cracks in the open. This
repo is about running that second thing, well, on infrastructure you control.

**What this repo adds:** the upstream project ships as an Alpine container aimed
at Vercel and Railway. This repo rebuilds it the way you'd run it in an
enterprise — on Red Hat's UBI 10 base images, hardened for OpenShift's
`restricted-v2` security context, built by a multi-arch CI pipeline that
generates SBOMs and gates on vulnerabilities, and deployed through Kustomize
overlays with one command.

So there are two halves:

1. **Build** — a nightly multi-arch (amd64 + arm64) pipeline that rebuilds both
   the app and its data relay on UBI 10, generates SPDX SBOMs, scans with Grype,
   fails the build on Critical CVEs, and publishes to Quay.
2. **Deploy** — Kustomize overlays for OpenShift Developer Sandbox (free tier),
   Single Node OpenShift with a GPU for local LLM inference, or plain Podman on
   a laptop. One script, namespace-portable, with a teardown path.

The result: the same live intelligence platform — vessels moving on the map,
chokepoint flows, conflict zones, market data, all seeding through Redis — but
running on images you built, scanned, and can audit end to end.

## Engineering highlights

The interesting parts aren't "it runs" — it's *how* it was made to run safely
and repeatably:

- **UBI 10, not Alpine.** Both images rebuilt on Red Hat's supported base
  (`ubi10/nodejs-24`, `ubi-minimal`), matching the app's Node 24 requirement
  with no version compromise.
- **No init system.** The upstream image runs supervisord to babysit nginx and a
  Node sidecar. This replaces it with a 40-line signal-handling shell entrypoint
  — smaller image, fewer CVEs, and a documented reason (`exec nginx` as PID 1
  silently orphans the sidecar on shutdown; the shell stays PID 1 instead).
- **Arbitrary-UID clean.** Runs under OpenShift's `restricted-v2` SCC with no
  privileged access — group-0 ownership, no baked-in root.
- **A real security supply chain.** Multi-arch build, SPDX SBOM per image, Grype
  scan, `--fail-on critical`. When the pipeline hit a genuine CVSS 9.2 in a
  transitive dependency, it *failed the build* — and the fix was a documented
  [VEX not-affected assessment](#on-the-cve-story), not a suppressed warning or
  a lowered gate.
- **Namespace-portable deploy.** Nothing hardcodes a namespace; the same
  overlays run on any cluster the current `oc` context points at, from a free
  Developer Sandbox to a GPU-equipped Single Node OpenShift.
- **Claude wired in.** Live LLM-assisted briefs via OpenRouter, with a preflight
  that verifies the model is actually reachable rather than silently falling back.

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


## Self-hosting fixes in this repo

Three gaps that stop a self-hosted deployment from working, none of them
documented upstream. Each is fixed here and verified against a running cluster:

**1. Hardcoded production RPC URLs.** The relay's warm-ping and RPC targets are
string constants pointing at `api.worldmonitor.app` with no env override, so a
self-hosted relay authenticates against upstream's production gateway and 401s.
Fixed with a fetch-layer preload (`WM_INTERNAL_API_BASE`) that rewrites the
origin — see `containers/Containerfile.ubi10-relay`.

**2. Undocumented auth requirements.** Key-gated endpoints need
`WORLDMONITOR_VALID_KEYS` on the app (allowlisting the relay's
`X-WorldMonitor-Key`) and `WM_SESSION_SECRET` so the app can mint browser
sessions. Without the latter, every browser request to a gated endpoint returns
401 "API key required" and the panels render UNAVAILABLE even though the API
computes the data correctly. Both are generated by `deploy.sh`.

**3. SRH path-style GET incompatibility.** `readCachedJson()` reads Redis with
`GET ${UPSTASH_REDIS_REST_URL}/get/<key>`. Upstash's hosted API serves that;
the self-hosted stand-in (serverless-redis-http) implements only the
POST-command form and 404s every path-style route. The 404 is treated as a
cache miss, so Redis-backed panels show "no data" while the data sits in Redis
— Security Advisories had 219 records stored and displayed 0. Fixed with a
second preload shim on the app image.

The first and third are one-line upstream fixes (make the constants
configurable; use the POST form or document the SRH requirement) and are worth
upstreaming.

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

Enforcement is a plain-ID ignore rule in `.grype.yaml`
(`- vulnerability: CVE-2026-59873`), not a `vex-status` rule. A `vex-status:
not_affected` ignore only fires when Grype has ALSO loaded a matching `--vex`
document; on its own it is inert and the CVE falls through to `--fail-on`. The
bare-ID ignore suppresses the match unconditionally, across npm and the rpm
false-matches on the same ID. `relay.openvex.json` remains the documented
rationale; `.grype.yaml` does the enforcement.

**The gate stays honest.** `--fail-on critical` is unchanged. The tar exception
is one documented, justified not-affected assessment — not a lowered bar. Any
*new* Critical, or one in code the relay actually reaches, still fails the build.

### Scope caveat

Grype scans OS and package metadata, not reachability. A clean scan means no
*known* CVEs in the dependency versions present (minus the documented VEX
exception), not that the application is free of vulnerabilities. For a claim
about application dependencies specifically, add `npm audit --production`.


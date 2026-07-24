# World Monitor — Red Hat UBI 10 image + nightly CI

Rebuild of [koala73/worldmonitor](https://github.com/koala73/worldmonitor) on
Red Hat UBI 10, with a nightly multi-arch pipeline pushing to
`quay.io/ryan_nix/worldmonitor-openshift`.

## What changed from upstream

| | Upstream | Here |
|---|---|---|
| Base | `node:24-alpine` | `ubi10/ubi-minimal` + `nodejs24` |
| Builder | `node:24-alpine` | `ubi10/nodejs-24` |
| Process supervisor | supervisord (Python) | shell, nginx + sidecar as children |
| Arbitrary UID | `USER appuser`, breaks under `restricted-v2` | `chgrp 0` + `chmod g=u`, `USER 1001` |
| Arch | amd64 | amd64 + arm64 manifest list |
| SBOM / scan | none | Syft SPDX + Grype, 90-day artifacts |

`.nvmrc` says Node 24 and `ubi10/nodejs-24` is GA, so there was no version
compromise to make.

## Why it stays a single container

The strong temptation is to split nginx and the Node sidecar into two
containers in one pod — that is the OpenShift-native shape and it removes the
need for any in-container supervision. I started there and backed out.

`docker/nginx.conf` proxies `/api/` to the sidecar like this:

```nginx
proxy_pass http://127.0.0.1:${LOCAL_API_PORT};
proxy_set_header Authorization "Bearer ${LOCAL_API_TOKEN}";
```

and `entrypoint.sh` generates `LOCAL_API_TOKEN` fresh on every start. The
sidecar binds loopback and trusts that bearer token — it is the trust boundary
between the two processes, and it never outlives the container.

Two containers in a pod still share a network namespace, so `127.0.0.1` keeps
working. But they could no longer agree on a token generated at start, so it
would have to become a Secret: long-lived, in etcd, readable by anyone with
`get secrets` in the namespace. That trades an ephemeral per-start secret for a
persistent one, to gain independent restarts of two processes that have no
independent value. The upstream design is better here.

## Why not supervisord, s6, or tini

supervisord is a Python runtime and its dependency tree, present to watch two
processes. s6-overlay works under `restricted-v2` (with `S6_READ_ONLY_ROOT=1`,
no `fix-attrs.d`, and group-writable scratch dirs prepared at build time) but
it is still a component added to preserve a design that does not need it.

`containers/entrypoint.sh` does the job in shell:

- sidecar starts as a background child, with a bounded wait for it to listen
- nginx starts as a second child
- `wait -n` returns on whichever exits first, and the container exits with it
- SIGTERM is forwarded to both, with a bounded wait then SIGKILL

### One thing worth knowing

The obvious form is `exec nginx -g 'daemon off;'` so nginx becomes PID 1.
**That silently breaks shutdown.** `exec` replaces the shell and discards the
trap with it, so SIGTERM reaches nginx but never the sidecar — which is then
orphaned and only dies via SIGKILL at the end of the grace period. Every
`oc delete pod` costs 30 seconds and an unclean shutdown.

This was verified experimentally rather than assumed, and it is why the shell
stays PID 1 and both processes are backgrounded children. Cost: one extra
process. Benefit: correct signal forwarding and reaping.

## Upstream pinning

`upstream.env` pins a commit SHA. Upstream's last tag is ~5 months old while
commits land daily — they ship from `main` and stopped tagging, so `v2.5.23`
is a stale marker rather than a release you would choose.

Building `main` nightly means debugging someone else's work in progress.
Freezing on the old tag means no fixes and growing CVE drift. Pinning a tested
SHA with a weekly bump PR gives reproducible builds plus a reviewed upgrade
path.

`upstream-sync.yml` opens that PR every Monday and flags any changes to
`package.json`, `.nvmrc`, `docker/`, `vite.config.ts`, or `tsconfig` — the
files that actually break a rebuild.

## On the CVE story

If this becomes customer-facing material, the honest framing is **"eliminated
the OS-package attack surface"**, not "zero CVEs."

Grype and Clair scan OS packages. This app's npm dependency graph is enormous —
the full deck.gl/three.js stack, 281 protos, 65+ data provider integrations. A
clean scan on the UBI base says nothing about that tree. The pipeline runs
`--fail-on critical` only, deliberately: UBI carries Low/Medium findings Red Hat
has triaged as not-affected, and failing on those makes the pipeline
permanently red, which means nobody reads it.

Add `npm audit --production` to the build if you want a defensible claim about
application dependencies.

## CI secrets

| Secret | Purpose |
|---|---|
| `QUAY_USERNAME` | Quay robot account, e.g. `ryan_nix+worldmonitor_ci` |
| `QUAY_PASSWORD` | That robot's token |

Use a robot account scoped to the one repository, not your personal
credentials. The robot needs **Write** on
`ryan_nix/worldmonitor-openshift` — Read is not enough to push, and Admin is
more than a CI job should hold.

Quay repos default to **private**. If you want OpenShift to pull without a
pull secret, flip it to public under Repository Settings, or add the robot's
credentials as a pull secret in the namespace:

```bash
oc create secret docker-registry quay-pull \
  --docker-server=quay.io \
  --docker-username='ryan_nix+worldmonitor_ci' \
  --docker-password='<robot token>'
oc secrets link default quay-pull --for=pull
```

## First run

```bash
git add -A && git commit -m "ci: UBI 10 image and nightly pipeline" && git push
gh workflow run build.yml          # or wait for the 07:00 UTC cron
gh run watch
```

The `resolve` job pins one commit for the whole run, so the amd64 and arm64
legs build identical source. Without that, a commit landing mid-run would
produce a manifest list whose two architectures came from different trees.

The smoke test runs on amd64 only and fails the build if:

- `/api/sidecar-health` never returns 200 (nginx up but sidecar dead, or vice versa)
- `/` does not serve HTML (the Vite build renames the SPA entry to
  `dashboard.html`; if that plugin changes upstream, nginx's `try_files` breaks
  and this catches it)
- the image's `USER` is not `1001` (a root default would fail `restricted-v2`)

## Licensing

Upstream is **AGPL-3.0-only**. These build files are separate work, but they do
not change the license of what they build. Self-hosting is clean; network-facing
modified deployments carry the source-availability obligation. Settle that
before this becomes a customer demo asset.

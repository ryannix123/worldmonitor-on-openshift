# World Monitor — run it locally with Podman

A live global-situation dashboard — armed conflict, military activity, aviation,
shipping, markets, and AI-written briefs — running entirely on your own machine.
No cluster, no cloud, no account. One script brings the whole stack up.

This is the local path for anyone who'd rather run containers with **Podman**
than Docker. If you're deploying to OpenShift instead, see the main
[README](./README.md).

> **Arm64 by default.** On Apple Silicon (M-series Macs) the prebuilt images
> pull and run with no changes. On Intel/AMD it's a one-line compose edit — see
> [Intel / AMD](#intel--amd-x86-64) at the end.

---

## Why Podman for this?

Podman does the same job as Docker here, but a few of its design choices matter
for a stack like this one:

- **No root daemon.** Docker runs everything through a single root-owned daemon;
  if it's compromised, so is the host. Podman is daemonless and runs your
  containers as *your* user, rootless by default. For a dashboard that pulls
  from the open internet all day, a smaller blast radius is the right default.
- **The containers already assume non-root.** These images run as an
  unprivileged user (UID 1001, the same restricted pattern OpenShift enforces).
  Podman's rootless model matches that exactly — what you run locally behaves
  like what runs in production, instead of "works as root on my laptop, breaks
  under the cluster's security policy."
- **No background service to babysit.** Nothing runs when you're not using it.
  The one Podman machine (a small Linux VM on macOS) starts when you want it and
  stops when you don't — no always-on daemon sitting in the background.
- **Same commands, drop-in.** `podman` is CLI-compatible with `docker`, and
  `podman compose` reads the same compose files. Nothing to relearn.

None of this requires Docker to be uninstalled — Podman coexists fine. It's just
the better fit for running a public-facing dashboard safely on a personal
machine.

---

## What you get

Four containers on a private network:

- `worldmonitor` — the dashboard (nginx + Node), on <http://localhost:3000>
- `ais-relay` — the seed loops that fetch UCDP, market, aviation and other data
- `redis` — the cache
- `redis-rest` — the Upstash-compatible REST proxy the app reads through

All prebuilt and pulled from Quay. Nothing compiles on your machine.

---

## Setup

### 1. Install Podman

```bash
brew install podman podman-compose
```

(Installing `podman-compose` gives `podman compose` a provider to use. If you
already have `docker-compose`, that works too — either satisfies it.)

### 2. Start Podman's engine

macOS runs containers in a small Linux VM. Create and start it once:

```bash
podman machine init
podman machine start
```

> **"only one VM can be active at a time"** just means you already have a Podman
> machine running. That's fine — skip `podman machine start` and continue.

### 3. Run it

```bash
cd podman
./deploy.sh
```

First run prompts for your API keys (only OpenRouter is needed for AI briefs;
the rest are optional and can be skipped with Enter), writes a `.env`, then
starts the stack. Later runs skip straight to starting.

Open <http://localhost:3000> once it's up. The map and news load immediately;
the conflict, military, and market panels fill in over 2–3 minutes as the feeds
catch up.

---

## Everyday use

```bash
./deploy.sh          # start (prompts for keys the first time)
./deploy.sh -stop    # stop, keeping your cached data
./deploy.sh -reset   # re-enter your keys from scratch
```

After a reboot the Podman engine stops too — `podman machine start`, then
`./deploy.sh`.

---

## Getting the API keys

All optional except OpenRouter (for AI briefs). Every panel degrades gracefully
without its key.

| Key | What it powers | Where |
|---|---|---|
| `OPENROUTER_API_KEY` | AI briefs (the route to Claude) | <https://openrouter.ai> |
| `UCDP_ACCESS_TOKEN` | Armed-conflict events | free token — see main README |
| `AISSTREAM_API_KEY` | Live vessel positions | <https://aisstream.io> |
| `ACLED_EMAIL` / `ACLED_PASSWORD` | Second conflict source | <https://acleddata.com> |

The two Redis values (`REDIS_PASSWORD`, `REDIS_TOKEN`) are generated for you —
you never type them.

---

## If something looks wrong

**Panels stuck on "Temporarily unavailable."** Give the relay 2–3 minutes on
first run. Still stuck? Restart: `./deploy.sh -stop && ./deploy.sh`.

**Nothing at localhost:3000.** Check all four containers are up with
`podman ps`. If not, run `./deploy.sh` again and watch for red error text.

**Curious what it's doing?**
`podman compose -f compose.local.yml logs -f worldmonitor` (Ctrl-C stops
watching, not the app).

---

## Intel / AMD (x86-64)

The images are multi-arch, so `podman compose` will pull the right one. The
compose file pins `platform: linux/arm64`; on an x86 machine, remove those four
`platform:` lines (or change them to `linux/amd64`) and it runs natively.

#!/usr/bin/env bash
# =============================================================================
# World Monitor — Apple Silicon bootstrap
# =============================================================================
# Provisions a Podman machine sized for this build, generates the two required
# secrets, and starts native Ollama. Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

MACHINE="${MACHINE:-worldmonitor}"
CPUS="${CPUS:-6}"
MEMORY_MB="${MEMORY_MB:-12288}"
DISK_GB="${DISK_GB:-60}"
MODEL="${MODEL:-llama3.2:3b}"

info() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$1"; }

# --- Podman machine ----------------------------------------------------------
# The Vite build plus tsc plus two corpus builders will OOM a default 2GB
# machine. These numbers are the floor, not a recommendation.
if podman machine inspect "$MACHINE" >/dev/null 2>&1; then
  info "Podman machine '$MACHINE' already exists"
else
  info "Creating Podman machine '$MACHINE' (${CPUS} vCPU, ${MEMORY_MB}MB, ${DISK_GB}GB)"
  podman machine init "$MACHINE" \
    --cpus "$CPUS" \
    --memory "$MEMORY_MB" \
    --disk-size "$DISK_GB"
fi

if podman machine inspect "$MACHINE" --format '{{.State}}' | grep -q running; then
  info "Machine already running"
else
  info "Starting machine"
  podman machine start "$MACHINE"
fi

# --- Secrets -----------------------------------------------------------------
# Both containers refuse to start without these (upstream issue #3804).
if [[ -f .env ]] && grep -q '^REDIS_PASSWORD=.\+' .env 2>/dev/null; then
  info ".env already has REDIS_PASSWORD — leaving it alone"
else
  info "Generating Redis credentials into .env"
  [[ -f .env ]] || cp .env.example .env
  RP="$(openssl rand -hex 32)"
  RT="$(openssl rand -hex 32)"
  # BSD sed on macOS needs the empty-string backup arg.
  sed -i '' "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${RP}|" .env
  sed -i '' "s|^REDIS_TOKEN=.*|REDIS_TOKEN=${RT}|" .env
fi

# --- Native Ollama -----------------------------------------------------------
if command -v ollama >/dev/null 2>&1; then
  if ! curl -sf http://127.0.0.1:11434/ >/dev/null 2>&1; then
    info "Starting Ollama in the background"
    nohup ollama serve >/tmp/ollama.log 2>&1 &
    sleep 3
  fi
  if ollama list 2>/dev/null | grep -q "${MODEL%%:*}"; then
    info "Model $MODEL already pulled"
  else
    info "Pulling $MODEL (this takes a few minutes)"
    ollama pull "$MODEL"
  fi
else
  warn "Ollama not found. Install with: brew install ollama"
  warn "The dashboard runs without it — AI summarization will be disabled."
fi

# --- Build and run -----------------------------------------------------------
info "Building and starting the stack"
podman compose -f docker-compose.yml -f podman/compose.arm64.yml up -d --build

cat <<'EOS'

  Stack is up.

  Dashboard:  http://localhost:3000
  Health:     curl -s http://localhost:3000/api/sidecar-health
  Logs:       podman compose logs -f worldmonitor
  Stop:       podman compose -f docker-compose.yml -f podman/compose.arm64.yml down

EOS

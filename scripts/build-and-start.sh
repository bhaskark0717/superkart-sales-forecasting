
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/workspaces/superkart-sales-forecasting"
cd "$PROJECT_DIR"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

for file in \
  backend/Dockerfile \
  frontend/Dockerfile \
  scripts/start-apps.sh
do
  [[ -f "$file" ]] || fail "Missing required file: $file"
done

log "Checking Docker..."
docker info >/dev/null 2>&1 ||
  fail "Docker is unavailable or unhealthy."

if ! docker image inspect superkart-backend:latest >/dev/null 2>&1; then
  log "Backend image missing; building it..."
  docker build -t superkart-backend:latest ./backend ||
    fail "Backend image build failed."
else
  log "Backend image exists; skipping build."
fi

if ! docker image inspect superkart-frontend:latest >/dev/null 2>&1; then
  log "Frontend image missing; building it..."
  docker build -t superkart-frontend:latest ./frontend ||
    fail "Frontend image build failed."
else
  log "Frontend image exists; skipping build."
fi

log "Verifying images..."
docker image inspect superkart-backend:latest >/dev/null ||
  fail "Backend image verification failed."
docker image inspect superkart-frontend:latest >/dev/null ||
  fail "Frontend image verification failed."

log "Starting SuperKart..."
bash scripts/start-apps.sh --lite

log "SuperKart startup completed."


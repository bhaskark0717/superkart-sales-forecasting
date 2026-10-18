
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

# Verify required files
for file in \
  backend/Dockerfile \
  frontend/Dockerfile \
  scripts/start-apps.sh
do
  [[ -f "$file" ]] || fail "Missing required file: $file"
done

# Verify Docker is responsive
log "Checking Docker..."
docker info >/dev/null 2>&1 ||
  fail "Docker is unavailable or unhealthy. Stop here and check Codespaces."

# Remove build cache only; preserve containers and volumes
log "Cleaning Docker build cache..."
docker builder prune -af ||
  fail "Build-cache cleanup failed. No containers or volumes were intentionally removed."

# Build backend
log "Building backend image..."
docker build --no-cache \
  -t superkart-backend:latest ./backend ||
  fail "Backend build failed. Check the Docker error above."

# Build frontend
log "Building frontend image..."
docker build --no-cache \
  -t superkart-frontend:latest ./frontend ||
  fail "Frontend build failed. Check the Docker error above."

# Verify both images
log "Verifying images..."
docker image inspect superkart-backend:latest >/dev/null ||
  fail "Backend image verification failed."

docker image inspect superkart-frontend:latest >/dev/null ||
  fail "Frontend image verification failed."

docker image ls \
  --filter reference=superkart-backend:latest \
  --filter reference=superkart-frontend:latest

# Start application using existing project script
log "Starting SuperKart..."
bash scripts/start-apps.sh

log "SuperKart startup script completed."


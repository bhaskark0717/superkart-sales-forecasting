#!/usr/bin/env bash
set -Eeuo pipefail

# SuperKart Sales Forecasting - Full Startup Script

NETWORK="superkart-net"

BACKEND_NAME="backend"
BACKEND_IMAGE="superkart-backend:latest"
BACKEND_PORT="7860"

FRONTEND_NAME="frontend"
FRONTEND_IMAGE="superkart-frontend:latest"
FRONTEND_PORT="8501"

MODE="${1:-full}"
LITE=0
[[ "$MODE" == "--lite" ]] && LITE=1

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

warn() {
    printf '\n[WARN] %s\n' "$*" >&2
}

fail() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 ||
    fail "Docker CLI is not available."

# --------------------------------------------------
# 1. Validate existing images
# --------------------------------------------------

log "Checking existing Docker images..."

docker image inspect "$BACKEND_IMAGE" >/dev/null 2>&1 ||
    fail "Missing image: $BACKEND_IMAGE. No image was rebuilt."

docker image inspect "$FRONTEND_IMAGE" >/dev/null 2>&1 ||
    fail "Missing image: $FRONTEND_IMAGE. No image was rebuilt."

# --------------------------------------------------
# 2. Ensure Docker network exists
# --------------------------------------------------

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    log "Creating Docker network: $NETWORK"
    docker network create "$NETWORK" >/dev/null
fi

# --------------------------------------------------
# 3. Recreate a container from its existing image
# --------------------------------------------------

recreate_container() {
    local name="$1"
    local image="$2"
    local port="$3"
    shift 3

    log "Recreating container '$name' from '$image'..."

    docker rm -f "$name" >/dev/null 2>&1 || true

    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        --network "$NETWORK" \
        -p "${port}:${port}" \
        "$image" "$@" >/dev/null

    log "Container '$name' recreated."
}

# --------------------------------------------------
# 4. Start or recover backend
# --------------------------------------------------

ensure_backend() {
    local recreate=0
    local error_file

    error_file="$(mktemp)"

    if docker container inspect "$BACKEND_NAME" \
        >/dev/null 2>"$error_file"; then

        if grep -Eqi 'RWLayer|unexpectedly nil' "$error_file"; then
            recreate=1
        fi

        local network_mode
        network_mode="$(docker inspect \
            -f '{{.HostConfig.NetworkMode}}' "$BACKEND_NAME")"

        local port_mapping
        port_mapping="$(docker port "$BACKEND_NAME" \
            "${BACKEND_PORT}/tcp" 2>/dev/null || true)"

        [[ "$network_mode" == "$NETWORK" ]] || recreate=1
        [[ -n "$port_mapping" ]] || recreate=1

        if ! docker inspect -f '{{.State.Running}}' \
            "$BACKEND_NAME" | grep -qx true; then

            if [[ "$recreate" -eq 0 ]]; then
                docker start "$BACKEND_NAME" >/dev/null
            fi
        fi

    else
        if grep -Eqi 'RWLayer|unexpectedly nil' "$error_file"; then
            warn "Detected Docker RWLayer error for backend."
        fi
        recreate=1
    fi

    rm -f "$error_file"

    if [[ "$recreate" -eq 1 ]]; then
        recreate_container \
            "$BACKEND_NAME" "$BACKEND_IMAGE" "$BACKEND_PORT" \
            gunicorn -w 4 -b 0.0.0.0:7860 app:superkart_api
    fi
}

ensure_frontend() {
    local recreate=0
    local error_file

    error_file="$(mktemp)"

    if docker container inspect "$FRONTEND_NAME" \
        >/dev/null 2>"$error_file"; then

        local network_mode
        network_mode="$(docker inspect \
            -f '{{.HostConfig.NetworkMode}}' "$FRONTEND_NAME")"

        local port_mapping
        port_mapping="$(docker port "$FRONTEND_NAME" \
            "${FRONTEND_PORT}/tcp" 2>/dev/null || true)"

        [[ "$network_mode" == "$NETWORK" ]] || recreate=1
        [[ -n "$port_mapping" ]] || recreate=1

        if ! docker inspect -f '{{.State.Running}}' \
            "$FRONTEND_NAME" | grep -qx true; then

            if [[ "$recreate" -eq 0 ]]; then
                docker start "$FRONTEND_NAME" >/dev/null
            fi
        fi

    else
        if grep -Eqi 'RWLayer|unexpectedly nil' "$error_file"; then
            warn "Detected Docker RWLayer error for frontend."
        fi
        recreate=1
    fi

    rm -f "$error_file"

    if [[ "$recreate" -eq 1 ]]; then
        recreate_container \
            "$FRONTEND_NAME" "$FRONTEND_IMAGE" "$FRONTEND_PORT" \
            streamlit run app.py \
            --server.port=8501 \
            --server.address=0.0.0.0 \
            --server.enableXsrfProtection=false
    fi
}

log "Starting backend..."
ensure_backend

log "Starting frontend..."
ensure_frontend

# --------------------------------------------------
# 5. Wait for both applications to respond
# --------------------------------------------------

wait_for_url() {
    local url="$1"
    local label="$2"
    local attempts=30

    for ((i = 1; i <= attempts; i++)); do
        if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
            log "PASS: $label is responding."
            return 0
        fi
        sleep 2
    done

    warn "$label did not respond at $url"
    return 1
}

log "Checking local application endpoints..."

wait_for_url "http://127.0.0.1:7860/" "Backend" ||
    warn "Check backend logs: docker logs --tail 60 backend"

wait_for_url "http://127.0.0.1:8501/" "Frontend" ||
    warn "Check frontend logs: docker logs --tail 60 frontend"

# --------------------------------------------------
# 6. Test frontend-to-backend connectivity
# --------------------------------------------------

log "Testing frontend-to-backend connectivity..."

if docker exec frontend python -c \
    "import urllib.request; r=urllib.request.urlopen('http://172.18.0.1:7860/', timeout=5); print(r.status, r.read().decode(errors='replace'))"
then
    log "PASS: Frontend can reach backend through 172.18.0.1:7860."
else
    warn "Configured backend URL failed. Testing Docker DNS..."

    if docker exec frontend python -c \
        "import urllib.request; r=urllib.request.urlopen('http://backend:7860/', timeout=5); print(r.status, r.read().decode(errors='replace'))"
    then
        warn "Docker DNS works. Review BACKEND_URL in frontend/app.py before switching URLs."
    else
        warn "Neither backend route passed. Inspect container logs and network rules."
    fi
fi

# --------------------------------------------------
# 7. Refresh firewall rules when supported
# --------------------------------------------------

if command -v iptables-legacy >/dev/null 2>&1; then
    FRONTEND_IP="$(docker inspect \
        -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" \
        frontend 2>/dev/null || true)"

    BACKEND_IP="$(docker inspect \
        -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" \
        backend 2>/dev/null || true)"

    if [[ -n "$FRONTEND_IP" && -n "$BACKEND_IP" ]]; then
        if sudo iptables-legacy -C FORWARD \
            -s "$FRONTEND_IP" -d "$BACKEND_IP" \
            -p tcp --dport 7860 -j ACCEPT 2>/dev/null; then
            log "Frontend-to-backend firewall rule already exists."
        elif sudo iptables-legacy -I FORWARD 1 \
            -s "$FRONTEND_IP" -d "$BACKEND_IP" \
            -p tcp --dport 7860 -j ACCEPT; then
            log "Added frontend-to-backend firewall rule."
        else
            warn "Could not add the frontend-to-backend firewall rule."
        fi

        if ! sudo iptables-legacy -C FORWARD \
            -s "$BACKEND_IP" -d "$FRONTEND_IP" \
            -p tcp --sport 7860 \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -j ACCEPT 2>/dev/null; then

            sudo iptables-legacy -I FORWARD 1 \
                -s "$BACKEND_IP" -d "$FRONTEND_IP" \
                -p tcp --sport 7860 \
                -m conntrack --ctstate ESTABLISHED,RELATED \
                -j ACCEPT 2>/dev/null ||
                warn "Could not add the established-response firewall rule."
        fi
    fi
else
    warn "iptables-legacy is unavailable; skipped firewall repair."
fi

# --------------------------------------------------
# 8. Set Codespaces port visibility
# --------------------------------------------------

if command -v gh >/dev/null 2>&1 &&
   [[ -n "${CODESPACE_NAME:-}" ]]; then

    log "Setting Codespaces port visibility to Public..."

    gh codespace ports visibility \
        7860:public -c "$CODESPACE_NAME" ||
        warn "Could not set backend port visibility."

    gh codespace ports visibility \
        8501:public -c "$CODESPACE_NAME" ||
        warn "Could not set frontend port visibility."

    gh codespace ports -c "$CODESPACE_NAME" || true
else
    warn "GitHub CLI or CODESPACE_NAME unavailable; skipped visibility settings."
fi

# --------------------------------------------------
# 9. Final report
# --------------------------------------------------

log "Container status:"
docker ps --filter name=backend --filter name=frontend

if [[ "$LITE" -eq 0 ]]; then
    log "Recent backend logs:"
    docker logs --tail 15 backend 2>&1 || true

    log "Recent frontend logs:"
    docker logs --tail 15 frontend 2>&1 || true
fi

printf '\n'
printf '%s\n' "=============================================="
printf '%s\n' " SuperKart startup checks completed"
printf '%s\n' " Backend:  http://localhost:7860"
printf '%s\n' " Frontend: http://localhost:8501"
printf '%s\n' "=============================================="
printf '%s\n' "No Docker image rebuild was performed."

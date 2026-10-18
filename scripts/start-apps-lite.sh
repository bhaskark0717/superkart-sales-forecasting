
#!/usr/bin/env bash
set -Eeuo pipefail

# SuperKart Sales Forecasting - Lightweight Startup
# Repair frontend-to-backend firewall rules, then delegate startup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/start-apps.sh"
NETWORK="superkart-net"

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

if [[ ! -f "$MAIN_SCRIPT" ]]; then
    echo "[ERROR] Main startup script not found: $MAIN_SCRIPT" >&2
    exit 1
fi

# Only attempt repair when both existing containers are available.
if command -v docker >/dev/null 2>&1 &&
   command -v iptables-legacy >/dev/null 2>&1 &&
   docker inspect frontend >/dev/null 2>&1 &&
   docker inspect backend >/dev/null 2>&1; then

    FRONTEND_IP="$(docker inspect \
        -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" \
        frontend 2>/dev/null || true)"

    BACKEND_IP="$(docker inspect \
        -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" \
        backend 2>/dev/null || true)"

    if [[ -n "$FRONTEND_IP" && -n "$BACKEND_IP" ]]; then
        log "Checking frontend-to-backend firewall rules..."

        if sudo -n iptables-legacy -C FORWARD \
            -s "$FRONTEND_IP" -d "$BACKEND_IP" \
            -p tcp --dport 7860 -j ACCEPT 2>/dev/null; then
            log "Forward rule already exists."
        elif sudo -n iptables-legacy -I FORWARD 1 \
            -s "$FRONTEND_IP" -d "$BACKEND_IP" \
            -p tcp --dport 7860 -j ACCEPT 2>/dev/null; then
            log "Added frontend-to-backend forward rule."
        else
            warn "Could not add forward rule; check sudo permissions and firewall."
        fi

        if sudo -n iptables-legacy -C FORWARD \
            -s "$BACKEND_IP" -d "$FRONTEND_IP" \
            -p tcp --sport 7860 \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -j ACCEPT 2>/dev/null; then
            log "Established-response rule already exists."
        elif sudo -n iptables-legacy -I FORWARD 1 \
            -s "$BACKEND_IP" -d "$FRONTEND_IP" \
            -p tcp --sport 7860 \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -j ACCEPT 2>/dev/null; then
            log "Added established-response rule."
        else
            warn "Could not add response rule; check sudo permissions and firewall."
        fi
    else
        warn "Could not determine both container IPs; skipping firewall repair."
    fi
else
    warn "Docker, iptables-legacy, or running containers unavailable; skipping pre-start repair."
fi

log "Delegating startup and recovery to start-apps.sh..."
exec bash "$MAIN_SCRIPT" --lite


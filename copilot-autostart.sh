#!/bin/zsh
# Copilot API Autostart Script for macOS
# Called by launchd at user login

WORK_DIR="${0:A:h}"
LOG_FILE="${WORK_DIR}/autostart.log"
PORT=4141
SERVICE_URL="http://localhost:${PORT}"
SERVICE_LOG="${WORK_DIR}/copilot-api.log"
WATCHDOG_SCRIPT="${WORK_DIR}/copilot-watchdog.sh"

# Load nvm so that node/npx are available (launchd doesn't source .zshrc)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}" 2>/dev/null
}

test_port_in_use() {
    lsof -i :${PORT} -sTCP:LISTEN >/dev/null 2>&1
}

test_watchdog_running() {
    pgrep -f "copilot-watchdog\.sh" > /dev/null 2>&1
}

log "Autostart triggered"
log "PATH: ${PATH}"
log "Node: $(which node 2>/dev/null || echo 'NOT FOUND')"
log "npx: $(which npx 2>/dev/null || echo 'NOT FOUND')"

# Wait for network to become available (up to 60s)
network_ready=false
for i in $(seq 1 12); do
    if curl -sf --max-time 3 https://api.github.com >/dev/null 2>&1; then
        network_ready=true
        log "Network ready after $((i * 5))s"
        break
    fi
    sleep 5
done
if [[ "$network_ready" == "false" ]]; then
    log "WARNING: Network not ready after 60s, proceeding anyway"
fi

# Start service with retry
max_retries=3
retry_delay=10
service_started=false

if ! test_port_in_use; then
    for i in $(seq 1 $max_retries); do
        log "Starting service (attempt ${i}/${max_retries})..."
        cd "${WORK_DIR}"
        nohup npx -y copilot-api@latest start --port ${PORT} >> "${SERVICE_LOG}" 2>&1 &

        # Wait up to 30 seconds for port to open
        for attempt in $(seq 1 30); do
            sleep 1
            if test_port_in_use; then
                log "Service started successfully"
                service_started=true
                break
            fi
        done

        if [[ "$service_started" == "true" ]]; then
            break
        fi

        log "Service start failed (attempt ${i}/${max_retries})"
        if [[ $i -lt $max_retries ]]; then
            log "Waiting ${retry_delay}s before retry..."
            sleep $retry_delay
        fi
    done

    if [[ "$service_started" == "false" ]]; then
        log "WARNING: Service failed to start after ${max_retries} attempts"
    fi
else
    log "Service already running on port ${PORT}"
    service_started=true
fi

# Start watchdog (regardless of service state - watchdog will handle restarts)
if ! test_watchdog_running; then
    if [[ -x "${WATCHDOG_SCRIPT}" ]]; then
        log "Starting watchdog..."
        nohup "${WATCHDOG_SCRIPT}" >> /dev/null 2>&1 &
        sleep 2
        if test_watchdog_running; then
            log "Watchdog started successfully"
        else
            log "WARNING: Watchdog start returned false"
        fi
    else
        log "WARNING: Watchdog script not found or not executable: ${WATCHDOG_SCRIPT}"
    fi
else
    log "Watchdog already running"
fi

log "Autostart completed"

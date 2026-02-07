#!/bin/zsh

PORT=4141
WORK_DIR="${0:A:h}"
LOG_FILE="${WORK_DIR}/copilot-api.log"
WATCHDOG_LOG_FILE="${WORK_DIR}/watchdog.log"
SERVICE_URL="http://localhost:${PORT}"
SHELL_CONFIG=""
HEALTH_CHECK_INTERVAL=30   # Health check interval in seconds
MAX_RESTART_ATTEMPTS=5     # Maximum restart attempts within cooldown period
RESTART_COOLDOWN=300       # Cooldown period in seconds (5 minutes)
WATCHDOG_SCRIPT="${WORK_DIR}/copilot-watchdog.sh"

detect_shell_config() {
    if [[ -f "$HOME/.zshrc" ]]; then
        SHELL_CONFIG="$HOME/.zshrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        SHELL_CONFIG="$HOME/.bash_profile"
    else
        SHELL_CONFIG="$HOME/.zshrc"
    fi
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

write_title() {
    echo "${CYAN}======================================${NC}"
    echo "${CYAN}  $1${NC}"
    echo "${CYAN}======================================${NC}"
    echo ""
}

write_success() {
    echo "${GREEN}[✓] $1${NC}"
}

write_error() {
    echo "${RED}[×] $1${NC}"
}

write_warning() {
    echo "${YELLOW}[!] $1${NC}"
}

write_info() {
    echo "${BLUE}[i] $1${NC}"
}

test_port_in_use() {
    local port=$1
    if lsof -i :${port} -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

get_service_pid() {
    lsof -ti :${PORT} -sTCP:LISTEN 2>/dev/null | head -1
}

# ==================== Model Functions ====================

fetch_models() {
    # Fetch available models from the API, returns JSON
    local response
    response=$(curl -s --max-time 10 "${SERVICE_URL}/v1/models" 2>/dev/null)
    if [[ $? -ne 0 || -z "$response" ]]; then
        echo ""
        return 1
    fi
    echo "$response"
}

filter_and_group_models() {
    # Takes JSON from stdin, filters out unwanted models, groups by vendor
    # Output format: one line per model: "vendor|id|display_name"
    local json="$1"
    echo "$json" | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
models = data.get('data', [])

# Filter criteria
skip_patterns = [
    r'^text-embedding',       # embedding models
    r'^goldeneye',            # internal models
    r'.*-copilot$',           # copilot-specific models
    r'^gpt-3\.5',             # outdated models
    r'^gpt-4-0',             # old dated gpt-4 variants
    r'^gpt-4$',              # base gpt-4
    r'^gpt-4-o-preview$',    # old preview alias
    r'^gpt-4o$',             # outdated standalone (superseded by gpt-4.1/5)
    r'^gpt-4o-mini$',        # outdated standalone (superseded by gpt-4.1-mini/5-mini)
    r'^gpt-4\.1$',           # base gpt-4.1 (dated version preferred)
    r'^gpt-4\.1-mini$',      # base gpt-4.1-mini (dated version preferred)
    r'^gpt-4\.1-nano$',      # base gpt-4.1-nano (dated version preferred)
]

# Also skip models with date suffixes like gpt-4o-2024-05-13
date_pattern = re.compile(r'-\d{4}-\d{2}-\d{2}$')

seen_ids = set()
filtered = []

for m in models:
    mid = m['id']
    display = m.get('display_name', mid)
    owned = m.get('owned_by', 'Unknown')
    
    # Skip duplicates
    if mid in seen_ids:
        continue
    
    # Skip by pattern
    skip = False
    for pat in skip_patterns:
        if re.match(pat, mid):
            skip = True
            break
    if skip:
        continue
    
    # Skip dated versions
    if date_pattern.search(mid):
        continue
    
    seen_ids.add(mid)
    
    # Normalize vendor name
    if 'anthropic' in owned.lower():
        vendor = 'Anthropic'
    elif 'openai' in owned.lower() or 'azure' in owned.lower():
        vendor = 'OpenAI'
    elif 'google' in owned.lower():
        vendor = 'Google'
    else:
        vendor = '其他'
    
    filtered.append((vendor, mid, display))

# Sort: Anthropic first, then OpenAI, then Google, then Other
vendor_order = {'Anthropic': 0, 'OpenAI': 1, 'Google': 2, '其他': 3}
filtered.sort(key=lambda x: (vendor_order.get(x[0], 99), x[1]))

for vendor, mid, display in filtered:
    print(f'{vendor}|{mid}|{display}')
"
}

select_model_from_list() {
    # Display grouped model list and let user pick one
    # Args: $1 = role label (e.g. "Sonnet (main model)" or "Haiku (fast model)")
    #        models are read from the variable MODEL_LIST (newline-separated "vendor|id|display_name")
    local role="$1"
    local current_vendor=""
    local index=0
    local -a model_ids
    local -a model_displays

    {
        echo ""
        echo "${WHITE}请选择 ${CYAN}${role}${WHITE} 的模型：${NC}"
        echo ""
        
        while IFS='|' read -r vendor mid display; do
            if [[ "$vendor" != "$current_vendor" ]]; then
                [[ -n "$current_vendor" ]] && echo ""
                echo "  ${YELLOW}=== ${vendor} ===${NC}"
                current_vendor="$vendor"
            fi
            ((index++))
            model_ids+=("$mid")
            model_displays+=("$display")
            echo "  ${index}. ${display} (${mid})"
        done <<< "$MODEL_LIST"
        
        echo ""
        echo "  0. 自定义模型"
        echo ""
        echo -n "请选择 (0-${index}): "
    } > /dev/tty
    
    local choice
    read choice < /dev/tty
    
    if [[ "$choice" == "0" ]]; then
        echo -n "请输入模型名称: " > /dev/tty
        local custom
        read custom < /dev/tty
        echo "$custom"
        return 0
    fi
    
    if [[ "$choice" -ge 1 && "$choice" -le "$index" ]] 2>/dev/null; then
        echo "${model_ids[$choice]}"
        return 0
    fi
    
    echo ""
    return 1
}

# ==================== Watchdog Functions ====================

write_watchdog_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] ${message}" >> "${WATCHDOG_LOG_FILE}" 2>/dev/null
}

test_service_health() {
    # Check if port is in use
    if ! test_port_in_use ${PORT}; then
        echo "Port not listening"
        return 1
    fi

    # Check API responsiveness
    if curl -s --max-time 10 "${SERVICE_URL}/v1/models" > /dev/null 2>&1; then
        echo "OK"
        return 0
    else
        echo "API request failed"
        return 1
    fi
}

start_service_internal() {
    # Start service without user interaction (for watchdog use)
    cd "${WORK_DIR}"
    nohup npx -y copilot-api@latest start --port ${PORT} >> "${LOG_FILE}" 2>&1 &

    # Wait for service to start (max 30 seconds)
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        sleep 1
        if test_port_in_use ${PORT}; then
            return 0
        fi
        ((attempt++))
    done
    return 1
}

stop_service_internal() {
    # Stop service without user interaction (for watchdog use)
    local pid=$(get_service_pid)
    if [[ -n "$pid" ]]; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.5
        return 0
    fi
    return 0
}

start_watchdog_internal() {
    # Stop existing watchdog if any
    stop_watchdog_internal
    sleep 0.5

    # Create the watchdog script
    cat > "${WATCHDOG_SCRIPT}" << 'WATCHDOG_EOF'
#!/bin/zsh
# Copilot API Watchdog Script
# Auto-generated - do not modify directly

WATCHDOG_PORT="__PORT__"
WATCHDOG_WORK_DIR="__WORK_DIR__"
WATCHDOG_LOG_FILE="__WATCHDOG_LOG_FILE__"
WATCHDOG_SERVICE_LOG="__LOG_FILE__"
WATCHDOG_SERVICE_URL="__SERVICE_URL__"
WATCHDOG_HEALTH_CHECK_INTERVAL=10
WATCHDOG_MAX_RESTART_ATTEMPTS=__MAX_RESTART_ATTEMPTS__
WATCHDOG_RESTART_COOLDOWN=__RESTART_COOLDOWN__
WATCHDOG_HEARTBEAT_INTERVAL=30

write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] ${message}" >> "${WATCHDOG_LOG_FILE}" 2>/dev/null
}

test_port() {
    lsof -i :${WATCHDOG_PORT} -sTCP:LISTEN >/dev/null 2>&1
}

test_health() {
    if ! test_port; then
        echo "Port not listening"
        return 1
    fi
    if curl -s --max-time 5 "${WATCHDOG_SERVICE_URL}/v1/models" > /dev/null 2>&1; then
        echo "OK"
        return 0
    else
        echo "API request failed"
        return 1
    fi
}

start_service() {
    write_log "Starting service..." "INFO"
    cd "${WATCHDOG_WORK_DIR}"
    nohup npx -y copilot-api@latest start --port ${WATCHDOG_PORT} >> "${WATCHDOG_SERVICE_LOG}" 2>&1 &

    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        sleep 1
        if test_port; then
            return 0
        fi
        ((attempt++))
    done
    return 1
}

stop_service() {
    local pid=$(lsof -ti :${WATCHDOG_PORT} -sTCP:LISTEN 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
}

# Main watchdog loop
write_log "Watchdog started (PID: $$)" "INFO"
restart_times=()
last_heartbeat=$(date +%s)

trap 'write_log "Watchdog stopped" "WARN"; exit 0' TERM INT

while true; do
    sleep ${WATCHDOG_HEALTH_CHECK_INTERVAL}

    # Heartbeat logging
    now=$(date +%s)
    if (( now - last_heartbeat >= WATCHDOG_HEARTBEAT_INTERVAL )); then
        write_log "Heartbeat: alive" "DEBUG"
        last_heartbeat=$now
    fi

    # Health check
    health_result=$(test_health)
    health_status=$?

    if [[ $health_status -ne 0 ]]; then
        write_log "Health failed: ${health_result}" "WARN"

        # Rate limiting: remove old restart times
        now=$(date +%s)
        new_restart_times=()
        for t in "${restart_times[@]}"; do
            if (( now - t < WATCHDOG_RESTART_COOLDOWN )); then
                new_restart_times+=("$t")
            fi
        done
        restart_times=("${new_restart_times[@]}")

        if (( ${#restart_times[@]} >= WATCHDOG_MAX_RESTART_ATTEMPTS )); then
            write_log "Rate limit exceeded" "ERROR"
            continue
        fi

        write_log "Restarting ($((${#restart_times[@]} + 1))/${WATCHDOG_MAX_RESTART_ATTEMPTS})..." "WARN"
        stop_service
        sleep 2

        if start_service; then
            write_log "Restarted OK" "INFO"
            restart_times+=("$now")
        else
            write_log "Restart failed" "ERROR"
        fi
    fi
done
WATCHDOG_EOF

    # Replace placeholders with actual values
    sed -i '' "s|__PORT__|${PORT}|g" "${WATCHDOG_SCRIPT}"
    sed -i '' "s|__WORK_DIR__|${WORK_DIR}|g" "${WATCHDOG_SCRIPT}"
    sed -i '' "s|__WATCHDOG_LOG_FILE__|${WATCHDOG_LOG_FILE}|g" "${WATCHDOG_SCRIPT}"
    sed -i '' "s|__LOG_FILE__|${LOG_FILE}|g" "${WATCHDOG_SCRIPT}"
    sed -i '' "s|__SERVICE_URL__|${SERVICE_URL}|g" "${WATCHDOG_SCRIPT}"
    sed -i '' "s|__MAX_RESTART_ATTEMPTS__|${MAX_RESTART_ATTEMPTS}|g" "${WATCHDOG_SCRIPT}"
    sed -i '' "s|__RESTART_COOLDOWN__|${RESTART_COOLDOWN}|g" "${WATCHDOG_SCRIPT}"

    chmod +x "${WATCHDOG_SCRIPT}"

    # Start watchdog in background
    nohup "${WATCHDOG_SCRIPT}" > /dev/null 2>&1 &
    local watchdog_pid=$!

    if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
        write_success "守护进程已启动 (PID: ${watchdog_pid})"
        return 0
    fi
    return 1
}

stop_watchdog_internal() {
    local pids=$(pgrep -f "copilot-watchdog\.sh" 2>/dev/null)
    if [[ -n "$pids" ]]; then
        echo "$pids" | while read pid; do
            kill "$pid" 2>/dev/null || true
        done
    fi
}

test_watchdog_running() {
    pgrep -f "copilot-watchdog\.sh" > /dev/null 2>&1
}

# ==================== UI Functions ====================

show_model_selection_menu() {
    local title="${1:-配置环境变量}"
    
    {
        clear
        write_title "$title"
        write_info "正在从 API 获取可用模型..."
    } > /dev/tty
    
    local json
    json=$(fetch_models)
    if [[ -z "$json" ]]; then
        {
            echo ""
            write_error "无法获取模型列表。服务是否在端口 ${PORT} 上运行？"
            write_info "请先启动服务（主菜单选项 1）"
            echo ""
        } > /dev/tty
        echo "FETCH_FAILED"
        return 1
    fi
    
    MODEL_LIST=$(filter_and_group_models "$json")
    if [[ -z "$MODEL_LIST" ]]; then
        {
            write_error "过滤后没有可用模型"
        } > /dev/tty
        echo "FETCH_FAILED"
        return 1
    fi
    
    {
        write_success "找到 $(echo "$MODEL_LIST" | wc -l | tr -d ' ') 个可用模型"
    } > /dev/tty
    
    # Step 1: Select Opus model (powerful model)
    local opus_model
    opus_model=$(select_model_from_list "Opus (强力模型)")
    if [[ -z "$opus_model" ]]; then
        echo "INVALID"
        return 1
    fi

    # Step 2: Select Sonnet model (main model)
    local sonnet_model
    sonnet_model=$(select_model_from_list "Sonnet (主模型)")
    if [[ -z "$sonnet_model" ]]; then
        echo "INVALID"
        return 1
    fi
    
    # Step 3: Select Haiku model (fast model)
    local haiku_model
    haiku_model=$(select_model_from_list "Haiku (快速模型)")
    if [[ -z "$haiku_model" ]]; then
        echo "INVALID"
        return 1
    fi
    
    # Return all 3 models separated by |
    echo "${opus_model}|${sonnet_model}|${haiku_model}"
    return 0
}

add_env_to_shell_config() {
    local var_name="$1"
    local var_value="$2"
    
    if [[ -f "$SHELL_CONFIG" ]]; then
        sed -i '' "/^export ${var_name}=/d" "$SHELL_CONFIG" 2>/dev/null || true
    fi
    
    echo "export ${var_name}=\"${var_value}\"" >> "$SHELL_CONFIG"
}

remove_env_from_shell_config() {
    local var_name="$1"
    
    if [[ -f "$SHELL_CONFIG" ]]; then
        sed -i '' "/^export ${var_name}=/d" "$SHELL_CONFIG" 2>/dev/null || true
    fi
}

set_environment_variables() {
    local opus_model="$1"
    local sonnet_model="$2"
    local haiku_model="$3"
    
    echo ""
    echo "${WHITE}将设置以下环境变量：${NC}"
    echo ""
    echo "  ANTHROPIC_BASE_URL = ${SERVICE_URL}"
    echo "  ANTHROPIC_MODEL = ${sonnet_model}"
    echo "  ANTHROPIC_DEFAULT_OPUS_MODEL = ${opus_model}"
    echo "  ANTHROPIC_DEFAULT_SONNET_MODEL = ${sonnet_model}"
    echo "  ANTHROPIC_SMALL_FAST_MODEL = ${haiku_model}"
    echo "  ANTHROPIC_DEFAULT_HAIKU_MODEL = ${haiku_model}"
    echo "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1"
    echo ""
    echo "${YELLOW}配置后，所有 Claude Code 会话将使用 Copilot API${NC}"
    echo "${YELLOW}配置文件: ${SHELL_CONFIG}${NC}"
    echo ""
    
    echo -n "确认设置环境变量？(Y/N): "
    read confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        write_warning "操作已取消"
        return 1
    fi
    
    echo ""
    echo "${CYAN}[开始设置环境变量]${NC}"
    
    add_env_to_shell_config "ANTHROPIC_BASE_URL" "${SERVICE_URL}"
    write_success "ANTHROPIC_BASE_URL"
    
    add_env_to_shell_config "ANTHROPIC_MODEL" "${sonnet_model}"
    write_success "ANTHROPIC_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_DEFAULT_OPUS_MODEL" "${opus_model}"
    write_success "ANTHROPIC_DEFAULT_OPUS_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_DEFAULT_SONNET_MODEL" "${sonnet_model}"
    write_success "ANTHROPIC_DEFAULT_SONNET_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_SMALL_FAST_MODEL" "${haiku_model}"
    write_success "ANTHROPIC_SMALL_FAST_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_DEFAULT_HAIKU_MODEL" "${haiku_model}"
    write_success "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    
    add_env_to_shell_config "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
    write_success "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    
    export ANTHROPIC_BASE_URL="${SERVICE_URL}"
    export ANTHROPIC_MODEL="${sonnet_model}"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${opus_model}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnet_model}"
    export ANTHROPIC_SMALL_FAST_MODEL="${haiku_model}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haiku_model}"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
    
    echo ""
    write_title "✓ 环境变量设置完成！"
    
    # Auto-restart service if it's running, so new env vars take effect
    if test_port_in_use ${PORT}; then
        echo ""
        write_info "正在重启服务以应用新环境变量..."
        stop_service_internal
        sleep 1
        if start_service_internal; then
            write_success "服务已使用新配置重启"
            # Restart watchdog too
            if test_watchdog_running; then
                stop_watchdog_internal
                start_watchdog_internal
            fi
        else
            write_error "服务重启失败，请手动重启（选项 1）"
        fi
    fi
    
    echo ""
    echo "${YELLOW}重要提示：${NC}"
    echo "  1. 运行 'source ${SHELL_CONFIG}' 以应用到当前终端"
    echo "  2. 新终端窗口将自动拥有这些变量"
    echo "  3. 重启 IDE/编辑器（如 VS Code）使更改生效"
    echo ""
    
    return 0
}

remove_environment_variables() {
    clear
    write_title "清除环境变量"
    
    echo "${WHITE}此操作将删除以下环境变量：${NC}"
    echo ""
    echo "  ANTHROPIC_BASE_URL"
    echo "  ANTHROPIC_MODEL"
    echo "  ANTHROPIC_DEFAULT_SONNET_MODEL"
    echo "  ANTHROPIC_DEFAULT_OPUS_MODEL"
    echo "  ANTHROPIC_SMALL_FAST_MODEL"
    echo "  ANTHROPIC_DEFAULT_HAIKU_MODEL"
    echo "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    echo ""
    echo "${YELLOW}清除后，Claude Code 将恢复使用 Anthropic 官方 API${NC}"
    echo ""
    
    echo -n "确认清除环境变量？(Y/N): "
    read confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        write_warning "操作已取消"
        return
    fi
    
    echo ""
    echo "${CYAN}[开始清除环境变量]${NC}"
    
    local variables=(
        "ANTHROPIC_BASE_URL"
        "ANTHROPIC_MODEL"
        "ANTHROPIC_DEFAULT_SONNET_MODEL"
        "ANTHROPIC_DEFAULT_OPUS_MODEL"
        "ANTHROPIC_SMALL_FAST_MODEL"
        "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    )
    
    for var in "${variables[@]}"; do
        remove_env_from_shell_config "$var"
        unset "$var"
        write_success "${var} 已删除"
    done
    
    # Also clean up any deprecated/unknown ANTHROPIC_ variables
    if [[ -f "$SHELL_CONFIG" ]]; then
        local deprecated_vars=$(grep "^export ANTHROPIC_" "$SHELL_CONFIG" 2>/dev/null | sed 's/^export \([^=]*\)=.*/\1/')
        if [[ -n "$deprecated_vars" ]]; then
            while IFS= read -r var; do
                remove_env_from_shell_config "$var"
                unset "$var" 2>/dev/null
                write_warning "${var} (已弃用) 已删除"
            done <<< "$deprecated_vars"
        fi
    fi
    
    echo ""
    write_title "✓ 环境变量清除完成！"
    echo "${YELLOW}重要提示：${NC}"
    echo "  1. 运行 'source ${SHELL_CONFIG}' 以应用到当前终端"
    echo "  2. 重启 IDE/编辑器（如 VS Code）使更改生效"
    echo "  3. 重启后将使用 Anthropic 官方 API"
    echo ""
}

start_copilot_service() {
    clear
    write_title "启动 Copilot API 服务"
    
    write_info "[1/4] 检查 Node.js..."
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        write_success "Node.js ${node_version}"
    else
        write_error "未找到 Node.js，请先安装 Node.js"
        echo ""
        echo "${CYAN}下载地址: https://nodejs.org/${NC}"
        return
    fi
    
    write_info "[2/4] 检查 copilot-api 包..."
    if npx -y copilot-api@latest --version &> /dev/null; then
        write_success "copilot-api 已就绪"
    else
        write_warning "无法验证 copilot-api 状态，将尝试继续"
    fi
    
    write_info "[3/4] 检查服务状态..."
    if test_port_in_use ${PORT}; then
        write_warning "端口 ${PORT} 已被占用，服务可能已在运行"
        echo ""
        echo -n "是否停止现有服务并重启？(Y/N): "
        read restart
        if [[ "$restart" == "Y" || "$restart" == "y" ]]; then
            stop_copilot_service true
            sleep 2
        else
            write_warning "操作已取消"
            return
        fi
    fi
    write_success "端口检查完成"
    
    write_info "[4/4] 启动 Copilot API 服务器..."
    echo ""
    echo "${YELLOW}如果出现提示，请在下方完成 GitHub 设备授权：${NC}"
    echo ""
    
    cd "${WORK_DIR}"
    # Start service in background, log to file only
    nohup npx -y copilot-api@latest start --port ${PORT} >> "${LOG_FILE}" 2>&1 &
    
    # Tail the log so user can see auth prompts during startup
    touch "${LOG_FILE}"
    tail -f "${LOG_FILE}" &
    local tail_pid=$!
    
    local max_attempts=30
    local attempt=0
    local service_started=false
    
    while [[ $attempt -lt $max_attempts ]]; do
        sleep 1
        if test_port_in_use ${PORT}; then
            service_started=true
            break
        fi
        ((attempt++))
    done
    
    # Stop tailing log output
    kill $tail_pid 2>/dev/null
    wait $tail_pid 2>/dev/null
    
    if [[ "$service_started" == "true" ]]; then
        echo ""
        write_success "服务启动成功"
        
        # Auto-start watchdog
        write_info "启动守护进程..."
        start_watchdog_internal
        
        echo ""
        write_title "✓ 启动完成！"
        echo "  ${GREEN}服务地址: ${SERVICE_URL}${NC}"
        echo "  工作目录: ${WORK_DIR}"
        echo "  日志文件: ${LOG_FILE}"
        echo "  ${CYAN}仪表盘: https://ericc-ch.github.io/copilot-api?endpoint=${SERVICE_URL}/usage${NC}"
        echo ""
        write_info "提示: 服务和守护进程已在后台运行，可以关闭此窗口"
        echo "  守护进程会在服务异常时自动重启"
    else
        echo ""
        write_warning "无法确认服务状态，请查看日志文件或手动检查"
        echo "  日志文件: ${LOG_FILE}"
    fi
    
    echo ""
}

stop_copilot_service() {
    local silent="${1:-false}"
    
    if [[ "$silent" != "true" ]]; then
        clear
        write_title "停止 Copilot API 服务"
    fi
    
    # Stop watchdog first
    if test_watchdog_running; then
        write_info "停止守护进程..."
        stop_watchdog_internal
        write_success "守护进程已停止"
    fi
    
    local pid=$(get_service_pid)
    if [[ -n "$pid" ]]; then
        write_info "找到进程 PID: ${pid}"
        kill -9 "$pid" 2>/dev/null || true
        write_success "服务已停止"
    else
        if [[ "$silent" != "true" ]]; then
            write_warning "未找到运行中的服务"
        fi
    fi
    
    sleep 0.5
    
    if ! test_port_in_use ${PORT}; then
        if [[ "$silent" != "true" ]]; then
            write_success "端口 ${PORT} 已释放"
        fi
    else
        write_warning "端口仍被占用，请手动检查"
    fi
    
    echo ""
}

show_service_status() {
    clear
    write_title "Copilot API 服务状态检查"
    
    echo "${CYAN}[检查环境]${NC}"
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        echo "  Node.js: ${GREEN}[✓] ${node_version}${NC}"
    else
        echo "  Node.js: ${RED}[×] 未安装${NC}"
    fi
    
    echo ""
    echo "${CYAN}[检查服务状态]${NC}"
    
    if test_port_in_use ${PORT}; then
        echo "  状态:      ${GREEN}[✓] 服务运行中${NC}"
        echo "  端口:      ${PORT} (使用中)"
        
        local pid=$(get_service_pid)
        if [[ -n "$pid" ]]; then
            echo "  进程ID: ${pid}"
        fi
        
        echo ""
        echo "${CYAN}[测试 API 连接]${NC}"
        if curl -s --max-time 5 "${SERVICE_URL}/v1/models" > /dev/null 2>&1; then
            echo "  连接:      ${GREEN}[✓] API 正常响应${NC}"
        else
            echo "  连接:      ${RED}[×] 无法连接到 API${NC}"
        fi
    else
        echo "  状态:      ${RED}[×] 服务未运行${NC}"
        echo "  端口:      ${PORT} (空闲)"
    fi
    
    echo ""
    echo "${CYAN}[检查环境变量]${NC}"
    
    if [[ -f "$SHELL_CONFIG" ]]; then
        local found_any=false
        while IFS= read -r line; do
            # Extract variable name and value from "export VAR_NAME="value""
            local var_name=$(echo "$line" | sed 's/^export \([^=]*\)=.*/\1/')
            local var_value=$(echo "$line" | cut -d'"' -f2)
            if [[ -n "$var_name" && -n "$var_value" ]]; then
                found_any=true
                echo "  ${var_name}: ${GREEN}[✓] ${var_value}${NC}"
            fi
        done < <(grep "^export ANTHROPIC_\|^export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=" "$SHELL_CONFIG")
        
        if [[ "$found_any" == "false" ]]; then
            echo "  ${RED}[×] 未配置任何环境变量${NC}"
        fi
    else
        echo "  ${RED}[×] 配置文件未找到 (${SHELL_CONFIG})${NC}"
    fi
    
    # Watchdog status
    echo ""
    echo "${CYAN}[守护进程状态]${NC}"
    if test_watchdog_running; then
        echo "  状态:      ${GREEN}[✓] 守护进程运行中${NC}"
        
        # Show recent watchdog log
        if [[ -f "${WATCHDOG_LOG_FILE}" ]]; then
            echo "  最近日志:"
            tail -3 "${WATCHDOG_LOG_FILE}" 2>/dev/null | while IFS= read -r log_line; do
                echo "    ${log_line}"
            done
        fi
    else
        echo "  状态:      ${YELLOW}[×] 守护进程未运行${NC}"
    fi
    
    echo ""
    echo "${CYAN}[其他信息]${NC}"
    echo "  工作目录: ${WORK_DIR}"
    if [[ -f "${LOG_FILE}" ]]; then
        echo "  服务日志: ${GREEN}[✓] ${LOG_FILE}${NC}"
    else
        echo "  服务日志: [-] 无日志文件"
    fi
    if [[ -f "${WATCHDOG_LOG_FILE}" ]]; then
        echo "  守护日志: ${GREEN}[✓] ${WATCHDOG_LOG_FILE}${NC}"
    fi
    echo "  ${CYAN}Dashboard: https://ericc-ch.github.io/copilot-api?endpoint=${SERVICE_URL}/usage${NC}"
    
    echo ""
    echo "${CYAN}======================================${NC}"
}

invoke_setup_env() {
    local result
    result=$(show_model_selection_menu "配置环境变量")
    local exit_code=$?
    
    if [[ "$result" == "FETCH_FAILED" || "$result" == "INVALID" || $exit_code -ne 0 ]]; then
        sleep 2
        return
    fi
    
    local opus_model="${result%%|*}"
    local rest="${result#*|}"
    local sonnet_model="${rest%%|*}"
    local haiku_model="${rest##*|}"
    
    if [[ -z "$opus_model" || -z "$sonnet_model" || -z "$haiku_model" ]]; then
        write_error "无效的模型选择"
        sleep 2
        return
    fi
    
    set_environment_variables "$opus_model" "$sonnet_model" "$haiku_model"
}

invoke_quick_start() {
    clear
    write_title "一键配置并启动"
    
    # Step 1: Start service if not running
    write_info "[步骤 1/3] 检查服务..."
    
    if ! test_port_in_use ${PORT}; then
        if ! command -v node &> /dev/null; then
            write_error "未找到 Node.js，请先安装 Node.js"
            return
        fi
        
        write_info "启动 Copilot API 服务器..."
        echo ""
        echo "${YELLOW}如果出现提示，请在下方完成 GitHub 设备授权：${NC}"
        echo ""
        
        cd "${WORK_DIR}"
        # Start service in background, log to file only
        nohup npx -y copilot-api@latest start --port ${PORT} >> "${LOG_FILE}" 2>&1 &
        
        # Tail the log so user can see auth prompts during startup
        touch "${LOG_FILE}"
        tail -f "${LOG_FILE}" &
        local tail_pid=$!
        
        local max_attempts=30
        local attempt=0
        local service_started=false
        
        while [[ $attempt -lt $max_attempts ]]; do
            sleep 1
            if test_port_in_use ${PORT}; then
                service_started=true
                break
            fi
            ((attempt++))
        done
        
        # Stop tailing log output
        kill $tail_pid 2>/dev/null
        wait $tail_pid 2>/dev/null
        
        if [[ "$service_started" != "true" ]]; then
            write_error "服务启动失败，请检查日志文件: ${LOG_FILE}"
            return
        fi
        write_success "服务启动完成"
    else
        write_success "服务已在运行"
    fi
    
    # Start watchdog
    if ! test_watchdog_running; then
        write_info "启动守护进程..."
        start_watchdog_internal
    fi
    
    # Step 2: Fetch models and let user select
    write_info "[步骤 2/3] 获取可用模型..."
    
    local result
    result=$(show_model_selection_menu "一键配置并启动")
    local exit_code=$?
    
    if [[ "$result" == "FETCH_FAILED" || "$result" == "INVALID" || $exit_code -ne 0 ]]; then
        echo ""
        write_warning "模型选择已取消。服务仍在运行。"
        return
    fi
    
    local opus_model="${result%%|*}"
    local rest="${result#*|}"
    local sonnet_model="${rest%%|*}"
    local haiku_model="${rest##*|}"
    
    if [[ -z "$opus_model" || -z "$sonnet_model" || -z "$haiku_model" ]]; then
        write_error "无效的模型选择"
        return
    fi
    
    # Step 3: Configure environment variables
    write_info "[步骤 3/3] 配置环境变量..."
    echo ""
    
    add_env_to_shell_config "ANTHROPIC_BASE_URL" "${SERVICE_URL}"
    add_env_to_shell_config "ANTHROPIC_MODEL" "${sonnet_model}"
    add_env_to_shell_config "ANTHROPIC_DEFAULT_OPUS_MODEL" "${opus_model}"
    add_env_to_shell_config "ANTHROPIC_DEFAULT_SONNET_MODEL" "${sonnet_model}"
    add_env_to_shell_config "ANTHROPIC_SMALL_FAST_MODEL" "${haiku_model}"
    add_env_to_shell_config "ANTHROPIC_DEFAULT_HAIKU_MODEL" "${haiku_model}"
    add_env_to_shell_config "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
    
    export ANTHROPIC_BASE_URL="${SERVICE_URL}"
    export ANTHROPIC_MODEL="${sonnet_model}"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${opus_model}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnet_model}"
    export ANTHROPIC_SMALL_FAST_MODEL="${haiku_model}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haiku_model}"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
    
    # Also remove deprecated vars if they exist
    remove_env_from_shell_config "ANTHROPIC_AUTH_TOKEN"
    remove_env_from_shell_config "DISABLE_NON_ESSENTIAL_MODEL_CALLS"
    unset ANTHROPIC_AUTH_TOKEN 2>/dev/null
    unset DISABLE_NON_ESSENTIAL_MODEL_CALLS 2>/dev/null
    
    write_success "环境变量配置完成"
    
    # Restart service to apply new env vars
    write_info "正在重启服务以应用新配置..."
    stop_service_internal
    sleep 1
    if start_service_internal; then
        write_success "服务已使用新配置重启"
        # Restart watchdog too
        if ! test_watchdog_running; then
            start_watchdog_internal
        else
            stop_watchdog_internal
            start_watchdog_internal
        fi
    else
        write_error "服务重启失败，请手动重启（选项 1）"
    fi
    
    echo ""
    write_title "✓ 配置和启动完成！"
    echo "  ${GREEN}服务地址: ${SERVICE_URL}${NC}"
    echo "  ${GREEN}Opus 模型: ${opus_model}${NC}"
    echo "  ${GREEN}Sonnet 模型: ${sonnet_model}${NC}"
    echo "  ${GREEN}Haiku 模型: ${haiku_model}${NC}"
    if test_watchdog_running; then
        echo "  ${GREEN}守护进程: 已启动 (自动监控重启)${NC}"
    fi
    echo "  工作目录: ${WORK_DIR}"
    echo "  ${CYAN}Dashboard: https://ericc-ch.github.io/copilot-api?endpoint=${SERVICE_URL}/usage${NC}"
    echo ""
    echo "${YELLOW}重要提示：${NC}"
    echo "  - 运行 'source ${SHELL_CONFIG}' 或重启终端使环境变量生效"
    echo "  - 重启 IDE/编辑器使更改生效"
    echo "  - 服务和守护进程在后台运行，关闭此窗口不影响运行"
    echo ""
}

show_main_menu() {
    detect_shell_config
    
    while true; do
        clear
        write_title "GitHub Copilot API 管理工具"
        
        echo "  工作目录: ${WORK_DIR}"
        echo "  Shell 配置: ${SHELL_CONFIG}"
        echo ""
        echo "  ${YELLOW}[服务管理]${NC}"
        echo "  ${GREEN}1. 启动服务 (含守护进程)${NC}"
        echo "  ${WHITE}2. 停止服务${NC}"
        echo "  ${WHITE}3. 检查服务状态${NC}"
        echo ""
        echo "  ${YELLOW}[环境配置]${NC}"
        echo "  ${WHITE}4. 配置环境变量${NC}"
        echo "  ${WHITE}5. 清除环境变量${NC}"
        echo ""
        echo "  ${YELLOW}[快捷操作]${NC}"
        echo "  ${CYAN}6. 一键配置并启动${NC}"
        echo "  0. 退出"
        echo ""
        echo "${CYAN}======================================${NC}"
        
        echo -n "请选择操作 (0-6): "
        read choice
        
        case "$choice" in
            1)
                start_copilot_service
                echo -n "按 Enter 继续..."
                read
                ;;
            2)
                stop_copilot_service
                echo -n "按 Enter 继续..."
                read
                ;;
            3)
                show_service_status
                echo -n "按 Enter 继续..."
                read
                ;;
            4)
                invoke_setup_env
                echo -n "按 Enter 继续..."
                read
                ;;
            5)
                remove_environment_variables
                echo -n "按 Enter 继续..."
                read
                ;;
            6)
                invoke_quick_start
                echo -n "按 Enter 继续..."
                read
                ;;
            0)
                echo "${CYAN}再见！${NC}"
                exit 0
                ;;
            *)
                write_warning "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

show_main_menu

#!/bin/zsh

PORT=4141
WORK_DIR="${0:A:h}"
LOG_FILE="${WORK_DIR}/copilot-api.log"
SERVICE_URL="http://localhost:${PORT}"
SHELL_CONFIG=""

detect_shell_config() {
    if [[ -f "$HOME/.zshrc" ]]; then
        SHELL_CONFIG="$HOME/.zshrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        SHELL_CONFIG="$HOME/.bash_profile"
    else
        SHELL_CONFIG="$HOME/.zshrc"
    fi
}

get_preset_name() {
    case "$1" in
        1) echo "gpt-5.1-codex (Sonnet) + gpt-5-mini (Haiku)" ;;
        2) echo "gpt-5.2 (Sonnet) + gpt-5-mini (Haiku)" ;;
        3) echo "gpt-5 (Sonnet) + gpt-5-mini (Haiku)" ;;
        4) echo "gpt-4.1 (Sonnet) + gpt-4o-mini (Haiku)" ;;
        5) echo "gpt-4o (Sonnet) + gpt-4o-mini (Haiku)" ;;
        6) echo "claude-sonnet-4.5 (Sonnet) + claude-haiku-4.5 (Haiku) [Recommended]" ;;
        7) echo "claude-opus-4.5 (Sonnet) + claude-haiku-4.5 (Haiku)" ;;
        8) echo "gemini-2.5-pro (Sonnet) + gemini-3-flash-preview (Haiku)" ;;
    esac
}

get_preset_sonnet() {
    case "$1" in
        1) echo "gpt-5.1-codex" ;;
        2) echo "gpt-5.2" ;;
        3) echo "gpt-5" ;;
        4) echo "gpt-4.1" ;;
        5) echo "gpt-4o" ;;
        6) echo "claude-sonnet-4.5" ;;
        7) echo "claude-opus-4.5" ;;
        8) echo "gemini-2.5-pro" ;;
    esac
}

get_preset_haiku() {
    case "$1" in
        1|2|3) echo "gpt-5-mini" ;;
        4|5) echo "gpt-4o-mini" ;;
        6|7) echo "claude-haiku-4.5" ;;
        8) echo "gemini-3-flash-preview" ;;
    esac
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

show_model_selection_menu() {
    local title="${1:-Configure Environment Variables}"
    
    {
        clear
        write_title "$title"
        echo "${WHITE}Please select a model configuration:${NC}"
        echo ""
        
        echo "  ${YELLOW}=== OpenAI GPT-5 Series ===${NC}"
        echo "  1. $(get_preset_name 1)"
        echo "  2. $(get_preset_name 2)"
        echo "  3. $(get_preset_name 3)"
        echo ""
        
        echo "  ${YELLOW}=== OpenAI GPT-4 Series ===${NC}"
        echo "  4. $(get_preset_name 4)"
        echo "  5. $(get_preset_name 5)"
        echo ""
        
        echo "  ${YELLOW}=== Anthropic Claude Series ===${NC}"
        echo "  6. ${GREEN}$(get_preset_name 6)${NC}"
        echo "  7. $(get_preset_name 7)"
        echo ""
        
        echo "  ${YELLOW}=== Google Gemini Series ===${NC}"
        echo "  8. $(get_preset_name 8)"
        echo ""
        
        echo "  ${YELLOW}=== Other ===${NC}"
        echo "  9. Custom model"
        echo "  0. Return to main menu"
        echo ""
        
        echo -n "Please select (0-9): "
    } > /dev/tty
    
    read choice < /dev/tty
    echo "$choice"
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
    local sonnet_model="$1"
    local haiku_model="$2"
    
    echo ""
    echo "${WHITE}The following environment variables will be set:${NC}"
    echo ""
    echo "  ANTHROPIC_BASE_URL = ${SERVICE_URL}"
    echo "  ANTHROPIC_AUTH_TOKEN = dummy"
    echo "  ANTHROPIC_MODEL = ${sonnet_model}"
    echo "  ANTHROPIC_DEFAULT_SONNET_MODEL = ${sonnet_model}"
    echo "  ANTHROPIC_SMALL_FAST_MODEL = ${haiku_model}"
    echo "  ANTHROPIC_DEFAULT_HAIKU_MODEL = ${haiku_model}"
    echo "  DISABLE_NON_ESSENTIAL_MODEL_CALLS = 1"
    echo "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1"
    echo ""
    echo "${YELLOW}After configuration, all Claude Code sessions will use Copilot API${NC}"
    echo "${YELLOW}Config file: ${SHELL_CONFIG}${NC}"
    echo ""
    
    echo -n "Confirm setting environment variables? (Y/N): "
    read confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        write_warning "Operation cancelled"
        return 1
    fi
    
    echo ""
    echo "${CYAN}[Setting environment variables]${NC}"
    
    add_env_to_shell_config "ANTHROPIC_BASE_URL" "${SERVICE_URL}"
    write_success "ANTHROPIC_BASE_URL"
    
    add_env_to_shell_config "ANTHROPIC_AUTH_TOKEN" "dummy"
    write_success "ANTHROPIC_AUTH_TOKEN"
    
    add_env_to_shell_config "ANTHROPIC_MODEL" "${sonnet_model}"
    write_success "ANTHROPIC_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_DEFAULT_SONNET_MODEL" "${sonnet_model}"
    write_success "ANTHROPIC_DEFAULT_SONNET_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_SMALL_FAST_MODEL" "${haiku_model}"
    write_success "ANTHROPIC_SMALL_FAST_MODEL"
    
    add_env_to_shell_config "ANTHROPIC_DEFAULT_HAIKU_MODEL" "${haiku_model}"
    write_success "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    
    add_env_to_shell_config "DISABLE_NON_ESSENTIAL_MODEL_CALLS" "1"
    write_success "DISABLE_NON_ESSENTIAL_MODEL_CALLS"
    
    add_env_to_shell_config "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
    write_success "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    
    export ANTHROPIC_BASE_URL="${SERVICE_URL}"
    export ANTHROPIC_AUTH_TOKEN="dummy"
    export ANTHROPIC_MODEL="${sonnet_model}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnet_model}"
    export ANTHROPIC_SMALL_FAST_MODEL="${haiku_model}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haiku_model}"
    export DISABLE_NON_ESSENTIAL_MODEL_CALLS="1"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
    
    echo ""
    write_title "Environment variables set successfully!"
    echo "${YELLOW}Important notes:${NC}"
    echo "  1. Run 'source ${SHELL_CONFIG}' to apply changes to current terminal"
    echo "  2. New terminal windows will have these variables automatically"
    echo "  3. Restart IDE/editor (e.g., VS Code) for changes to take effect"
    echo ""
    
    return 0
}

remove_environment_variables() {
    clear
    write_title "Clear Environment Variables"
    
    echo "${WHITE}The following environment variables will be removed:${NC}"
    echo ""
    echo "  ANTHROPIC_BASE_URL"
    echo "  ANTHROPIC_AUTH_TOKEN"
    echo "  ANTHROPIC_MODEL"
    echo "  ANTHROPIC_DEFAULT_SONNET_MODEL"
    echo "  ANTHROPIC_SMALL_FAST_MODEL"
    echo "  ANTHROPIC_DEFAULT_HAIKU_MODEL"
    echo "  DISABLE_NON_ESSENTIAL_MODEL_CALLS"
    echo "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    echo ""
    echo "${YELLOW}After clearing, Claude Code will use official Anthropic API${NC}"
    echo ""
    
    echo -n "Confirm clearing environment variables? (Y/N): "
    read confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        write_warning "Operation cancelled"
        return
    fi
    
    echo ""
    echo "${CYAN}[Clearing environment variables]${NC}"
    
    local variables=(
        "ANTHROPIC_BASE_URL"
        "ANTHROPIC_AUTH_TOKEN"
        "ANTHROPIC_MODEL"
        "ANTHROPIC_DEFAULT_SONNET_MODEL"
        "ANTHROPIC_SMALL_FAST_MODEL"
        "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        "DISABLE_NON_ESSENTIAL_MODEL_CALLS"
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    )
    
    for var in "${variables[@]}"; do
        remove_env_from_shell_config "$var"
        unset "$var"
        write_success "${var} removed"
    done
    
    echo ""
    write_title "Environment variables cleared successfully!"
    echo "${YELLOW}Important notes:${NC}"
    echo "  1. Run 'source ${SHELL_CONFIG}' to apply changes to current terminal"
    echo "  2. Restart IDE/editor (e.g., VS Code) for changes to take effect"
    echo "  3. After restart, Claude Code will use official Anthropic API"
    echo ""
}

start_copilot_service() {
    clear
    write_title "Start Copilot API Service"
    
    write_info "[1/4] Checking Node.js..."
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        write_success "Node.js ${node_version}"
    else
        write_error "Node.js not found, please install Node.js first"
        echo ""
        echo "${CYAN}Download from: https://nodejs.org/${NC}"
        return
    fi
    
    write_info "[2/4] Checking copilot-api package..."
    if npx -y copilot-api@latest --version &> /dev/null; then
        write_success "copilot-api is ready"
    else
        write_warning "Cannot verify copilot-api status, will try to continue"
    fi
    
    write_info "[3/4] Checking service status..."
    if test_port_in_use ${PORT}; then
        write_warning "Port ${PORT} is already in use, service may be running"
        echo ""
        echo -n "Stop existing service and restart? (Y/N): "
        read restart
        if [[ "$restart" == "Y" || "$restart" == "y" ]]; then
            stop_copilot_service true
            sleep 2
        else
            write_warning "Operation cancelled"
            return
        fi
    fi
    write_success "Port check complete"
    
    write_info "[4/4] Starting Copilot API server..."
    echo ""
    echo "${YELLOW}If prompted, please complete GitHub device authorization below:${NC}"
    echo ""
    
    cd "${WORK_DIR}"
    npx -y copilot-api@latest start --port ${PORT} 2>&1 | tee "${LOG_FILE}" &
    local service_pid=$!
    
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
    
    if [[ "$service_started" == "true" ]]; then
        echo ""
        write_title "Service started successfully!"
        echo "  ${GREEN}Service URL: ${SERVICE_URL}${NC}"
        echo "  Working directory: ${WORK_DIR}"
        echo "  Log file: ${LOG_FILE}"
        echo "  ${CYAN}Dashboard: https://ericc-ch.github.io/copilot-api?endpoint=${SERVICE_URL}/usage${NC}"
        echo ""
        write_info "Tip: Service is running in background, you can close this window"
    else
        echo ""
        write_warning "Cannot confirm service status, please check log file or manually verify"
        echo "  Log file: ${LOG_FILE}"
    fi
    
    echo ""
}

stop_copilot_service() {
    local silent="${1:-false}"
    
    if [[ "$silent" != "true" ]]; then
        clear
        write_title "Stop Copilot API Service"
    fi
    
    local pid=$(get_service_pid)
    if [[ -n "$pid" ]]; then
        write_info "Found process PID: ${pid}"
        kill -9 "$pid" 2>/dev/null || true
        write_success "Service stopped"
    else
        write_warning "No running service found"
    fi
    
    sleep 0.5
    
    if ! test_port_in_use ${PORT}; then
        write_success "Port ${PORT} released"
    else
        write_warning "Port still in use, please check manually"
    fi
    
    echo ""
}

show_service_status() {
    clear
    write_title "Copilot API Service Status Check"
    
    echo "${CYAN}[Environment Check]${NC}"
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        echo "  Node.js: ${GREEN}[✓] ${node_version}${NC}"
    else
        echo "  Node.js: ${RED}[×] Not installed${NC}"
    fi
    
    echo ""
    echo "${CYAN}[Service Status Check]${NC}"
    
    if test_port_in_use ${PORT}; then
        echo "  Status:    ${GREEN}[✓] Service running${NC}"
        echo "  Port:      ${PORT} (in use)"
        
        local pid=$(get_service_pid)
        if [[ -n "$pid" ]]; then
            echo "  Process ID: ${pid}"
        fi
        
        echo ""
        echo "${CYAN}[API Connection Test]${NC}"
        if curl -s --max-time 5 "${SERVICE_URL}/v1/models" > /dev/null 2>&1; then
            echo "  Connection: ${GREEN}[✓] API responding normally${NC}"
        else
            echo "  Connection: ${RED}[×] Cannot connect to API${NC}"
        fi
    else
        echo "  Status:    ${RED}[×] Service not running${NC}"
        echo "  Port:      ${PORT} (available)"
    fi
    
    echo ""
    echo "${CYAN}[Environment Variables Check]${NC}"
    
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
        done < <(grep "^export ANTHROPIC_\|^export DISABLE_NON_ESSENTIAL_MODEL_CALLS=\|^export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=" "$SHELL_CONFIG" 2>/dev/null)
        
        if [[ "$found_any" == "false" ]]; then
            echo "  ${RED}[×] No environment variables configured${NC}"
        fi
    else
        echo "  ${RED}[×] Config file not found (${SHELL_CONFIG})${NC}"
    fi
    
    echo ""
    echo "${CYAN}[Other Information]${NC}"
    echo "  Working directory: ${WORK_DIR}"
    if [[ -f "${LOG_FILE}" ]]; then
        echo "  Log file: ${GREEN}[✓] ${LOG_FILE}${NC}"
    else
        echo "  Log file: [-] No log file"
    fi
    echo "  ${CYAN}Dashboard: https://ericc-ch.github.io/copilot-api?endpoint=${SERVICE_URL}/usage${NC}"
    
    echo ""
    echo "${CYAN}======================================${NC}"
}

invoke_setup_env() {
    local choice=$(show_model_selection_menu "Configure Environment Variables")
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    local sonnet_model=""
    local haiku_model=""
    
    if [[ "$choice" == "9" ]]; then
        echo ""
        echo -n "Please enter Sonnet model name: "
        read sonnet_model
        echo -n "Please enter Haiku model name: "
        read haiku_model
        
        if [[ -z "$sonnet_model" || -z "$haiku_model" ]]; then
            write_error "Model name cannot be empty"
            sleep 2
            return
        fi
    elif [[ -n "$(get_preset_sonnet $choice)" ]]; then
        sonnet_model="$(get_preset_sonnet $choice)"
        haiku_model="$(get_preset_haiku $choice)"
    else
        write_error "Invalid selection"
        sleep 2
        return
    fi
    
    set_environment_variables "$sonnet_model" "$haiku_model"
}

invoke_quick_start() {
    local choice=$(show_model_selection_menu "One-Click Configure and Start")
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    local sonnet_model=""
    local haiku_model=""
    
    if [[ "$choice" == "9" ]]; then
        echo ""
        echo -n "Please enter Sonnet model name: "
        read sonnet_model
        echo -n "Please enter Haiku model name: "
        read haiku_model
        
        if [[ -z "$sonnet_model" || -z "$haiku_model" ]]; then
            write_error "Model name cannot be empty"
            sleep 2
            return
        fi
    elif [[ -n "$(get_preset_sonnet $choice)" ]]; then
        sonnet_model="$(get_preset_sonnet $choice)"
        haiku_model="$(get_preset_haiku $choice)"
    else
        write_error "Invalid selection"
        sleep 2
        return
    fi
    
    clear
    write_title "One-Click Configure and Start"
    
    echo "${WHITE}This will:${NC}"
    echo "  1. Configure environment variables (Sonnet: ${sonnet_model}, Haiku: ${haiku_model})"
    echo "  2. Start Copilot API service"
    echo ""
    
    echo -n "Confirm execution? (Y/N): "
    read confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        write_warning "Operation cancelled"
        return
    fi
    
    echo ""
    write_info "[Step 1/2] Configuring environment variables..."
    
    add_env_to_shell_config "ANTHROPIC_BASE_URL" "${SERVICE_URL}"
    add_env_to_shell_config "ANTHROPIC_AUTH_TOKEN" "dummy"
    add_env_to_shell_config "ANTHROPIC_MODEL" "${sonnet_model}"
    add_env_to_shell_config "ANTHROPIC_DEFAULT_SONNET_MODEL" "${sonnet_model}"
    add_env_to_shell_config "ANTHROPIC_SMALL_FAST_MODEL" "${haiku_model}"
    add_env_to_shell_config "ANTHROPIC_DEFAULT_HAIKU_MODEL" "${haiku_model}"
    add_env_to_shell_config "DISABLE_NON_ESSENTIAL_MODEL_CALLS" "1"
    add_env_to_shell_config "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
    
    export ANTHROPIC_BASE_URL="${SERVICE_URL}"
    export ANTHROPIC_AUTH_TOKEN="dummy"
    export ANTHROPIC_MODEL="${sonnet_model}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnet_model}"
    export ANTHROPIC_SMALL_FAST_MODEL="${haiku_model}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haiku_model}"
    export DISABLE_NON_ESSENTIAL_MODEL_CALLS="1"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
    
    write_success "Environment variables configured"
    
    echo ""
    write_info "[Step 2/2] Starting service..."
    
    if ! command -v node &> /dev/null; then
        write_error "Node.js not found, please install Node.js first"
        return
    fi
    
    if test_port_in_use ${PORT}; then
        write_info "Service already running, skipping start"
    else
        echo ""
        echo "${YELLOW}If prompted, please complete GitHub device authorization below:${NC}"
        echo ""
        
        cd "${WORK_DIR}"
        npx -y copilot-api@latest start --port ${PORT} 2>&1 | tee "${LOG_FILE}" &
        
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
        
        if [[ "$service_started" == "true" ]]; then
            write_success "Service started"
        else
            write_warning "Cannot confirm service status, please check manually"
        fi
    fi
    
    echo ""
    write_title "Configuration and Start Complete!"
    echo "  ${GREEN}Service URL: ${SERVICE_URL}${NC}"
    echo "  Working directory: ${WORK_DIR}"
    echo "  ${CYAN}Dashboard: https://ericc-ch.github.io/copilot-api?endpoint=${SERVICE_URL}/usage${NC}"
    echo ""
    echo "${YELLOW}Important notes:${NC}"
    echo "  - Run 'source ${SHELL_CONFIG}' or restart terminal for env vars to take effect"
    echo "  - Restart IDE/editor for changes to take effect"
    echo "  - Service is running in background, closing this window won't affect it"
    echo ""
}

show_main_menu() {
    detect_shell_config
    
    while true; do
        clear
        write_title "GitHub Copilot API Management Tool (macOS)"
        
        echo "  Working directory: ${WORK_DIR}"
        echo "  Shell config: ${SHELL_CONFIG}"
        echo ""
        echo "  ${WHITE}1. Configure environment variables${NC}"
        echo "  ${WHITE}2. Clear environment variables${NC}"
        echo "  ${WHITE}3. Start Copilot API service${NC}"
        echo "  ${WHITE}4. Stop Copilot API service${NC}"
        echo "  ${WHITE}5. Check service status${NC}"
        echo "  ${GREEN}6. One-click configure and start${NC}"
        echo "  0. Exit"
        echo ""
        echo "${CYAN}======================================${NC}"
        
        echo -n "Please select (0-6): "
        read choice
        
        case "$choice" in
            1)
                invoke_setup_env
                echo -n "Press Enter to continue..."
                read
                ;;
            2)
                remove_environment_variables
                echo -n "Press Enter to continue..."
                read
                ;;
            3)
                start_copilot_service
                echo -n "Press Enter to continue..."
                read
                ;;
            4)
                stop_copilot_service
                echo -n "Press Enter to continue..."
                read
                ;;
            5)
                show_service_status
                echo -n "Press Enter to continue..."
                read
                ;;
            6)
                invoke_quick_start
                echo -n "Press Enter to continue..."
                read
                ;;
            0)
                echo "${CYAN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                write_warning "Invalid selection, please try again"
                sleep 1
                ;;
        esac
    done
}

show_main_menu

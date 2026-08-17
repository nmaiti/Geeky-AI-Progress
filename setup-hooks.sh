#!/usr/bin/env bash
set -e

# ==========================================
# Helper Functions: Logging & UI
# ==========================================
log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

print_banner() {
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

# ==========================================
# Dependency Checks
# ==========================================
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        log_error "'jq' is required for payload parsing. Please install it (e.g., sudo apt install jq or pacman -S jq)."
        exit 1
    fi
}

# ==========================================
# IP & URL Normalization (--url IP:PORT support)
# ==========================================
detect_server_url() {
    local custom_url=""

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --url) custom_url="$2"; shift ;;
        esac
        shift
    done

    if [ -n "$custom_url" ]; then
        # Prepend http:// if protocol is omitted
        if [[ ! "$custom_url" =~ ^https?:// ]]; then
            custom_url="http://$custom_url"
        fi
        # Append /api/agent/event if endpoint path is omitted
        if [[ ! "$custom_url" =~ /api/agent/event ]]; then
            custom_url="${custom_url%/}"
            custom_url="${custom_url}/api/agent/event"
        fi
        echo "$custom_url"
        return
    fi

    local host_ip=""
    if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win32"* ]]; then
        host_ip=$(ipconfig.exe 2>/dev/null | grep -i "IPv4" | head -n 1 | cut -d: -f2 | tr -d ' \r')
    else
        if command -v hostname &> /dev/null && hostname -I &> /dev/null; then
            host_ip=$(hostname -I | awk '{print $1}')
        elif command -v ip &> /dev/null; then
            host_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
        fi
    fi

    if [ -z "$host_ip" ]; then
        host_ip="localhost"
    fi

    echo "http://$host_ip:5000/api/agent/event"
}

# ==========================================
# Generate Shared `notify.sh` Script
# ==========================================
setup_notify_script() {
    local server_url="$1"
    local config_dir="$HOME/.config/ai-agent-leds"
    local notify_file="$config_dir/notify.sh"
    
    mkdir -p "$config_dir"
    log_info "Generating shared notification script at $notify_file..."

    cat << 'EOF' > "$notify_file"
#!/usr/bin/env bash
SERVER_URL="PLACEHOLDER_URL"
SOURCE="${1:-unknown}"
EVENT_TYPE="${2:-unknown}"

TOOL_NAME="unknown"
INPUT=""

if [ ! -t 0 ]; then
    INPUT=$(cat)
    if command -v jq &> /dev/null; then
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .toolName // .tool // .name // "unknown"' 2>/dev/null)
        if [ "$TOOL_NAME" = "null" ] || [ -z "$TOOL_NAME" ]; then
            TOOL_NAME="unknown"
        fi
    fi
fi

PAYLOAD=$(jq -n \
  --arg src "$SOURCE" \
  --arg evt "$EVENT_TYPE" \
  --arg tool "$TOOL_NAME" \
  '{source: $src, event_type: $evt, tool_name: $tool}')

curl -s -X POST "$SERVER_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  >/dev/null 2>&1 || true
EOF

    sed -i.bak "s|PLACEHOLDER_URL|$server_url|g" "$notify_file" && rm -f "${notify_file}.bak"
    chmod +x "$notify_file"
}

# ==========================================
# 1. Claude Code Hooks Setup
# ==========================================
setup_claude_hooks() {
    local notify_bin="$HOME/.config/ai-agent-leds/notify.sh"
    local claude_dir="$HOME/.claude"
    local claude_settings="$claude_dir/settings.json"
    
    mkdir -p "$claude_dir"

    if [ -f "$claude_settings" ]; then
        log_info "[Claude] Backing up existing settings.json to settings.json.bak"
        cp "$claude_settings" "${claude_settings}.bak"
    fi

    log_info "[Claude] Configuring global hooks in $claude_settings..."
    cat << EOF > "$claude_settings"
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "$notify_bin claude session_start"
      }
    ],
    "PreToolUse": [
      {
        "type": "command",
        "command": "$notify_bin claude pre_tool_use"
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "$notify_bin claude session_end"
      }
    ]
  }
}
EOF
}

# ==========================================
# 2. GitHub Copilot CLI Hooks Setup
# ==========================================
setup_copilot_hooks() {
    local notify_bin="$HOME/.config/ai-agent-leds/notify.sh"
    local copilot_dir="$HOME/.copilot/hooks"
    local copilot_file="$copilot_dir/led-monitor.json"

    mkdir -p "$copilot_dir"

    if [ -f "$copilot_file" ]; then
        log_info "[Copilot] Backing up existing led-monitor.json to led-monitor.json.bak"
        cp "$copilot_file" "${copilot_file}.bak"
    fi

    log_info "[Copilot] Configuring global hooks in $copilot_file..."
    cat << EOF > "$copilot_file"
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "type": "command",
        "bash": "$notify_bin copilot session_start",
        "powershell": "& '$HOME/.config/ai-agent-leds/notify.sh' copilot session_start"
      }
    ],
    "preToolUse": [
      {
        "type": "command",
        "bash": "$notify_bin copilot pre_tool_use",
        "powershell": "& '$HOME/.config/ai-agent-leds/notify.sh' copilot pre_tool_use"
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "$notify_bin copilot session_end",
        "powershell": "& '$HOME/.config/ai-agent-leds/notify.sh' copilot session_end"
      }
    ]
  }
}
EOF
}

# ==========================================
# 3. Cline Extension Hooks Setup (~/.cline/hooks/)
# ==========================================
setup_cline_hooks() {
    local notify_bin="$HOME/.config/ai-agent-leds/notify.sh"
    local cline_dir="$HOME/.cline/hooks"
    
    mkdir -p "$cline_dir"

    if [ -f "$cline_dir/taskStart" ] && [ ! -f "$cline_dir/taskStart.bak" ]; then
        cp "$cline_dir/taskStart" "$cline_dir/taskStart.bak"
    fi
    if [ -f "$cline_dir/preToolUse" ] && [ ! -f "$cline_dir/preToolUse.bak" ]; then
        cp "$cline_dir/preToolUse" "$cline_dir/preToolUse.bak"
    fi
    if [ -f "$cline_dir/taskCancel" ] && [ ! -f "$cline_dir/taskCancel.bak" ]; then
        cp "$cline_dir/taskCancel" "$cline_dir/taskCancel.bak"
    fi

    log_info "[Cline] Creating global executable hook scripts in $cline_dir..."

    cat << EOF > "$cline_dir/taskStart"
#!/usr/bin/env bash
$notify_bin cline session_start
echo '{"cancel": false}'
EOF
    chmod +x "$cline_dir/taskStart"

    cat << EOF > "$cline_dir/preToolUse"
#!/usr/bin/env bash
$notify_bin cline pre_tool_use
echo '{"cancel": false}'
EOF
    chmod +x "$cline_dir/preToolUse"

    cat << EOF > "$cline_dir/taskCancel"
#!/usr/bin/env bash
$notify_bin cline session_end
echo '{"cancel": false}'
EOF
    chmod +x "$cline_dir/taskCancel"
}

# ==========================================
# 4. Kilo Code Global Config Setup (~/.config/kilo/)
# ==========================================
setup_kilo_hooks() {
    local server_url="$1"
    local kilo_dir="$HOME/.config/kilo"
    local kilo_config="$kilo_dir/kilo.jsonc"

    mkdir -p "$kilo_dir"

    if [ -f "$kilo_config" ]; then
        log_info "[Kilo] Backing up existing kilo.jsonc to kilo.jsonc.bak"
        cp "$kilo_config" "${kilo_config}.bak"
    fi

    log_info "[Kilo] Configuring event telemetry hook in $kilo_config..."
    cat << EOF > "$kilo_config"
{
  "agentHooks": {
    "url": "$server_url",
    "enabled": true
  }
}
EOF
}

# ==========================================
# Cleanup & Backup Restoration (-c / --clean)
# ==========================================
clean_hooks() {
    print_banner "Cleaning Up All Agent Hooks & Restoring Backups"

    if [ -d "$HOME/.config/ai-agent-leds" ]; then
        log_info "Removing shared notify.sh script directory..."
        rm -rf "$HOME/.config/ai-agent-leds"
    fi

    local claude_settings="$HOME/.claude/settings.json"
    if [ -f "${claude_settings}.bak" ]; then
        log_info "[Claude] Restoring settings.json from backup..."
        mv "${claude_settings}.bak" "$claude_settings"
    elif [ -f "$claude_settings" ]; then
        rm -f "$claude_settings"
    fi

    local copilot_file="$HOME/.copilot/hooks/led-monitor.json"
    if [ -f "${copilot_file}.bak" ]; then
        log_info "[Copilot] Restoring led-monitor.json from backup..."
        mv "${copilot_file}.bak" "$copilot_file"
    elif [ -f "$copilot_file" ]; then
        rm -f "$copilot_file"
    fi

    local cline_dir="$HOME/.cline/hooks"
    if [ -f "$cline_dir/taskStart.bak" ]; then
        mv "$cline_dir/taskStart.bak" "$cline_dir/taskStart"
    else
        rm -f "$cline_dir/taskStart"
    fi
    if [ -f "$cline_dir/preToolUse.bak" ]; then
        mv "$cline_dir/preToolUse.bak" "$cline_dir/preToolUse"
    else
        rm -f "$cline_dir/preToolUse"
    fi
    if [ -f "$cline_dir/taskCancel.bak" ]; then
        mv "$cline_dir/taskCancel.bak" "$cline_dir/taskCancel"
    else
        rm -f "$cline_dir/taskCancel"
    fi
    log_info "[Cline] Restored/cleaned hook scripts."

    local kilo_config="$HOME/.config/kilo/kilo.jsonc"
    if [ -f "${kilo_config}.bak" ]; then
        log_info "[Kilo] Restoring kilo.jsonc from backup..."
        mv "${kilo_config}.bak" "$kilo_config"
    elif [ -f "$kilo_config" ]; then
        rm -f "$kilo_config"
    fi

    print_banner "Cleanup & Backup Restoration Complete!"
    exit 0
}

# ==========================================
# Main Execution Flow
# ==========================================
main() {
    if [ "$1" = "-c" ] || [ "$1" = "--clean" ]; then
        clean_hooks
    fi

    check_dependencies

    local server_url
    server_url=$(detect_server_url "$@")

    print_banner "Configuring Multi-Agent Telemetry via notify.sh"
    log_info "Target Endpoint: $server_url"

    setup_notify_script "$server_url"
    setup_claude_hooks
    setup_copilot_hooks
    setup_cline_hooks
    setup_kilo_hooks "$server_url"

    print_banner "Setup Complete! Backups stored and hooks configured."
}

main "$@"
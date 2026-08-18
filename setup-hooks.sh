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
    if command -v jq &> /dev/null; then
        return
    fi

    # On Windows Git Bash / MSYS / Cygwin, auto-download jq if missing
    if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win32"* ]]; then
        log_info "'jq' not found. Downloading jq for Windows (amd64)..."
        local jq_dir="$HOME/.config/ai-agent-leds/bin"
        mkdir -p "$jq_dir"
        local jq_bin="$jq_dir/jq.exe"
        local jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"

        if curl -L --fail -o "$jq_bin" "$jq_url"; then
            chmod +x "$jq_bin"
            export PATH="$jq_dir:$PATH"
            log_info "jq installed to $jq_bin"
            return
        else
            log_error "Failed to download jq. Install it manually and retry."
            exit 1
        fi
    fi

    log_error "'jq' is required for payload parsing. Please install it (e.g., sudo apt install jq or pacman -S jq)."
    exit 1
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
TOOLS="[]"
TOOLSETS="[]"
HOSTNAME="unknown"
USER="unknown"
ENV_CURRENT_TIME="unknown"
ENV_WORKING_DIRECTORY="unknown"
ENV_WORKSPACE_ROOT="unknown"
RAW_PAYLOAD=""

if [ ! -t 0 ]; then
    INPUT=$(cat)
    if command -v jq &> /dev/null; then
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .toolName // .tool // .name // .tool.name // "unknown"' 2>/dev/null)
        if [ "$TOOL_NAME" = "null" ] || [ -z "$TOOL_NAME" ]; then
            TOOL_NAME="unknown"
        fi
        TOOLS=$(echo "$INPUT" | jq -c '[.tools // [] | .[]? | select(type == "string")] | if length == 0 then [] else . end' 2>/dev/null)
        TOOLSETS=$(echo "$INPUT" | jq -c '[.toolsets // [] | .[]? | select(type == "string")] | if length == 0 then [] else . end' 2>/dev/null)
        HOSTNAME=$(echo "$INPUT" | jq -r '.hostname // empty' 2>/dev/null)
        USER=$(echo "$INPUT" | jq -r '.user // empty' 2>/dev/null)
        EXISTING_RAW=$(echo "$INPUT" | jq -r '.raw_payload // empty' 2>/dev/null)
        if [ -n "$EXISTING_RAW" ] && [ "$EXISTING_RAW" != "null" ]; then
            RAW_PAYLOAD="$EXISTING_RAW"
        else
            RAW_PAYLOAD="$INPUT"
        fi
    else
        RAW_PAYLOAD="$INPUT"
    fi
else
    RAW_PAYLOAD=""
fi

if [ "$HOSTNAME" = "null" ] || [ -z "$HOSTNAME" ]; then
    HOSTNAME=$(hostname 2>/dev/null || echo "$HOSTNAME")
fi
if [ "$HOSTNAME" = "null" ] || [ -z "$HOSTNAME" ]; then
    HOSTNAME="${HOST:-unknown}"
fi
if [ "$HOSTNAME" = "null" ] || [ -z "$HOSTNAME" ]; then
    HOSTNAME="unknown"
fi

if [ "$USER" = "null" ] || [ -z "$USER" ]; then
    USER="${USERNAME:-${USER:-unknown}}"
    if [ "$USER" = "unknown" ] && [ -n "$INPUT" ]; then
        EXTRACTED_USER=$(echo "$INPUT" | grep -oP 'C:\\\\Users\\\\[^\\/]+' | head -n1 | sed 's/C:\\\\Users\\\\//' | sed 's/\\\\//g')
        if [ -n "$EXTRACTED_USER" ]; then
            USER="$EXTRACTED_USER"
        else
            EXTRACTED_USER=$(echo "$INPUT" | grep -oP '/home/[^\\/]+' | head -n1 | sed 's/\\/home\\///')
            if [ -n "$EXTRACTED_USER" ]; then
                USER="$EXTRACTED_USER"
            else
                EXTRACTED_USER=$(echo "$INPUT" | grep -oP 'Working directory: [A-Z]:\\\\Users\\\\[^\\/]+' | head -n1 | sed 's/Working directory: [A-Z]:\\\\Users\\\\//' | sed 's/\\\\//g')
                if [ -n "$EXTRACTED_USER" ]; then
                    USER="$EXTRACTED_USER"
                fi
            fi
        fi
    fi
fi
if [ "$USER" = "null" ] || [ -z "$USER" ]; then
    USER="unknown"
fi

if [ -n "$INPUT" ]; then
    ENV_CURRENT_TIME=$(echo "$INPUT" | grep -oP 'Current time: \K[^\r\n]+' | head -n1)
    ENV_WORKING_DIRECTORY=$(echo "$INPUT" | grep -oP 'Working directory: \K[^\r\n]+' | head -n1)
    ENV_WORKSPACE_ROOT=$(echo "$INPUT" | grep -oP 'Workspace root folder: \K[^\r\n]+' | head -n1)
fi
if [ "$ENV_CURRENT_TIME" = "null" ] || [ -z "$ENV_CURRENT_TIME" ]; then
    ENV_CURRENT_TIME="unknown"
fi
if [ "$ENV_WORKING_DIRECTORY" = "null" ] || [ -z "$ENV_WORKING_DIRECTORY" ]; then
    ENV_WORKING_DIRECTORY="unknown"
fi
if [ "$ENV_WORKSPACE_ROOT" = "null" ] || [ -z "$ENV_WORKSPACE_ROOT" ]; then
    ENV_WORKSPACE_ROOT="unknown"
fi

PAYLOAD=$(jq -n \
  --arg src "$SOURCE" \
  --arg evt "$EVENT_TYPE" \
  --arg tool "$TOOL_NAME" \
  --argjson tools "$TOOLS" \
  --argjson toolsets "$TOOLSETS" \
  --arg host "$HOSTNAME" \
  --arg user "$USER" \
  --arg env_time "$ENV_CURRENT_TIME" \
  --arg env_cwd "$ENV_WORKING_DIRECTORY" \
  --arg env_root "$ENV_WORKSPACE_ROOT" \
  --arg raw "$RAW_PAYLOAD" \
  '{source: $src, event_type: $evt, tool_name: $tool, tools: $tools, toolsets: $toolsets, hostname: $host, user: $user, env_current_time: $env_time, env_working_directory: $env_cwd, env_workspace_root: $env_root, raw_payload: $raw}')

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
INPUT=\$(cat)
TASK_ID=\$(echo "\$INPUT" | jq -r '.taskId // empty')
HOOK_NAME=\$(echo "\$INPUT" | jq -r '.hookName // empty')
WORKSPACE=\$(echo "\$INPUT" | jq -r '.workspaceRoots[0] // empty')
HOSTNAME=\$(hostname 2>/dev/null || echo "unknown")
USER="unknown"
if [ -n "\$WORKSPACE" ]; then
    EXTRACTED_USER=\$(echo "\$WORKSPACE" | grep -oP 'C:\\\\Users\\\\[^\\/]+' | head -n1 | sed 's/C:\\\\Users\\\\//' | sed 's/\\\\//g')
    if [ -z "\$EXTRACTED_USER" ]; then
        EXTRACTED_USER=\$(echo "\$WORKSPACE" | grep -oP '/home/[^\\/]+' | head -n1 | sed 's/\\/home\\///')
    fi
    if [ -n "\$EXTRACTED_USER" ]; then
        USER="\$EXTRACTED_USER"
    else
        USER="\${USERNAME:-\${USER:-unknown}}"
    fi
fi
EVENT_TYPE="session_start"
case "\$HOOK_NAME" in
    TaskResume) EVENT_TYPE="session_start" ;;
    TaskComplete) EVENT_TYPE="session_end" ;;
    TaskCancel) EVENT_TYPE="session_end" ;;
esac
PAYLOAD=\$(jq -n \
  --arg src "cline" \
  --arg evt "\$EVENT_TYPE" \
  --arg session "\$TASK_ID" \
  --arg host "\$HOSTNAME" \
  --arg user "\$USER" \
  --arg raw "\$INPUT" \
  '\{source: \$src, event_type: \$evt, session_id: \$session, hostname: \$host, user: \$user, raw_payload: \$raw}')
echo "\$PAYLOAD" | "$notify_bin" cline "\$EVENT_TYPE"
echo '{"cancel": false}'
EOF
    chmod +x "$cline_dir/taskStart"

    cat << EOF > "$cline_dir/preToolUse"
#!/usr/bin/env bash
INPUT=\$(cat)
TASK_ID=\$(echo "\$INPUT" | jq -r '.taskId // empty')
TOOL_NAME=\$(echo "\$INPUT" | jq -r '.preToolUse.tool // empty')
WORKSPACE=\$(echo "\$INPUT" | jq -r '.workspaceRoots[0] // empty')
HOSTNAME=\$(hostname 2>/dev/null || echo "unknown")
USER="unknown"
if [ -n "\$WORKSPACE" ]; then
    EXTRACTED_USER=\$(echo "\$WORKSPACE" | grep -oP 'C:\\\\Users\\\\[^\\/]+' | head -n1 | sed 's/C:\\\\Users\\\\//' | sed 's/\\\\//g')
    if [ -z "\$EXTRACTED_USER" ]; then
        EXTRACTED_USER=\$(echo "\$WORKSPACE" | grep -oP '/home/[^\\/]+' | head -n1 | sed 's/\\/home\\///')
    fi
    if [ -n "\$EXTRACTED_USER" ]; then
        USER="\$EXTRACTED_USER"
    else
        USER="\${USERNAME:-\${USER:-unknown}}"
    fi
fi
if [ -z "\$TOOL_NAME" ] || [ "\$TOOL_NAME" = "null" ]; then
    TOOL_NAME="unknown"
fi
PAYLOAD=\$(jq -n \
  --arg src "cline" \
  --arg evt "pre_tool_use" \
  --arg session "\$TASK_ID" \
  --arg tool "\$TOOL_NAME" \
  --arg host "\$HOSTNAME" \
  --arg user "\$USER" \
  --arg raw "\$INPUT" \
  '\{source: \$src, event_type: \$evt, session_id: \$session, tool_name: \$tool, hostname: \$host, user: \$user, raw_payload: \$raw}')
echo "\$PAYLOAD" | "$notify_bin" cline "pre_tool_use"
echo '{"cancel": false}'
EOF
    chmod +x "$cline_dir/preToolUse"

    cat << EOF > "$cline_dir/taskCancel"
#!/usr/bin/env bash
INPUT=\$(cat)
TASK_ID=\$(echo "\$INPUT" | jq -r '.taskId // empty')
HOOK_NAME=\$(echo "\$INPUT" | jq -r '.hookName // empty')
WORKSPACE=\$(echo "\$INPUT" | jq -r '.workspaceRoots[0] // empty')
HOSTNAME=\$(hostname 2>/dev/null || echo "unknown")
USER="unknown"
if [ -n "\$WORKSPACE" ]; then
    EXTRACTED_USER=\$(echo "\$WORKSPACE" | grep -oP 'C:\\\\Users\\\\[^\\/]+' | head -n1 | sed 's/C:\\\\Users\\\\//' | sed 's/\\\\//g')
    if [ -z "\$EXTRACTED_USER" ]; then
        EXTRACTED_USER=\$(echo "\$WORKSPACE" | grep -oP '/home/[^\\/]+' | head -n1 | sed 's/\\/home\\///')
    fi
    if [ -n "\$EXTRACTED_USER" ]; then
        USER="\$EXTRACTED_USER"
    else
        USER="\${USERNAME:-\${USER:-unknown}}"
    fi
fi
EVENT_TYPE="session_end"
case "\$HOOK_NAME" in
    TaskResume) EVENT_TYPE="session_start" ;;
    TaskComplete) EVENT_TYPE="session_end" ;;
esac
PAYLOAD=\$(jq -n \
  --arg src "cline" \
  --arg evt "\$EVENT_TYPE" \
  --arg session "\$TASK_ID" \
  --arg host "\$HOSTNAME" \
  --arg user "\$USER" \
  --arg raw "\$INPUT" \
  '\{source: \$src, event_type: \$evt, session_id: \$session, hostname: \$host, user: \$user, raw_payload: \$raw}')
echo "\$PAYLOAD" | "$notify_bin" cline "\$EVENT_TYPE"
echo '{"cancel": false}'
EOF
    chmod +x "$cline_dir/taskCancel"
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

    print_banner "Setup Complete! Backups stored and hooks configured."
}

main "$@"
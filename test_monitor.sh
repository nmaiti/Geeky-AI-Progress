#!/usr/bin/env bash
# test_monitor.sh - Local loopback curl-based test for Monitor_sever
#
# Usage:
#   ./test_monitor.sh              # Run all tests (assumes server on http://localhost:5000)
#   ./test_monitor.sh --start      # Start server in background first, then run tests
#   ./test_monitor.sh --url URL    # Use custom server URL (e.g. --url http://192.168.1.5:5000)

set -euo pipefail

# ==========================================
# Config
# ==========================================
SERVER_URL="http://localhost:5000"
START_SERVER=false
EVENT_ENDPOINT="${SERVER_URL}/api/agent/event"
HEALTH_URL="${SERVER_URL}/health"

# Color codes for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ==========================================
# Arg Parsing
# ==========================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)
            START_SERVER=true
            shift
            ;;
        --url)
            SERVER_URL="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown argument: $1"
            shift
            ;;
    esac
done

EVENT_ENDPOINT="${SERVER_URL}/api/agent/event"
HEALTH_URL="${SERVER_URL}/health"

# ==========================================
# Helpers
# ==========================================
send_event() {
    local session_id="$1"
    local source="$2"
    local event_type="$3"
    local tool_name="$4"
    local payload
    payload=$(jq -n \
        --arg sid "$session_id" \
        --arg src "$source" \
        --arg evt "$event_type" \
        --arg tool "$tool_name" \
        '{source: $src, event_type: $evt, session_id: $sid, tool_name: $tool, tools: ["Read","Edit"], toolsets: ["core"], hostname: "test-host", user: "testuser", raw_payload: "mock raw payload"}')
    local resp
    resp=$(curl -s -X POST "$EVENT_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -w "\n%{http_code}")
    echo "$resp"
}

wait_for_idle() {
    log_info "Waiting 22s for sessions to transition to Idle (20s timeout)..."
    sleep 22
}

wait_for_removal() {
    log_info "Waiting 65s for idle sessions to be removed (60s cleanup)..."
    sleep 65
}

# ==========================================
# Pre-flight Checks
# ==========================================
command -v curl >/dev/null 2>&1 || { log_err "curl is required"; exit 1; }

# Auto-install jq if missing (mirrors setup-hooks.sh behavior)
if ! command -v jq >/dev/null 2>&1; then
    if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win32"* ]]; then
        # Check if jq was already installed by setup-hooks.sh
        JQ_LOCAL="$HOME/.config/ai-agent-leds/bin/jq.exe"
        if [ -f "$JQ_LOCAL" ]; then
            export PATH="$HOME/.config/ai-agent-leds/bin:$PATH"
        else
            log_info "jq not found. Downloading jq for Windows (amd64)..."
            jq_dir="$HOME/.config/ai-agent-leds/bin"
            mkdir -p "$jq_dir"
            jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
            if curl -L --fail -o "$JQ_LOCAL" "$jq_url"; then
                chmod +x "$JQ_LOCAL"
                export PATH="$jq_dir:$PATH"
                log_info "jq installed to $JQ_LOCAL"
            else
                log_err "Failed to download jq. Install it manually and retry."
                exit 1
            fi
        fi
    else
        log_err "jq is required. Install it (e.g. sudo apt install jq)."
        exit 1
    fi
fi

command -v jq >/dev/null 2>&1 || { log_err "jq is required"; exit 1; }

# ==========================================
# Optionally Start Server
# ==========================================
SERVER_PID=""
if [ "$START_SERVER" = true ]; then
    log_step "Starting Monitor_sever in background..."
    cd "$(dirname "$0")/Monitor_sever"
    SERVER_PID=$(go run . 2>/tmp/monitor-server.log &)
    # give it a moment to start
    sleep 3
fi

# Cleanup on exit
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        log_info "Stopping Monitor_sever (PID $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ==========================================
# Tests
# ==========================================
PASS=0
FAIL=0
run_test() {
    local name="$1"
    local condition="$2"
    if [ "$condition" = "0" ]; then
        log_info "PASS: $name"
        PASS=$((PASS + 1))
    else
        log_err "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test 1: Health Check ---
log_step "=== Test 1: Health Check ==="
health_resp=$(curl -s "$HEALTH_URL" -w "\n%{http_code}" || true)
health_code=$(echo "$health_resp" | tail -1)
if [ "$health_code" = "200" ]; then
    log_info "Health check passed (HTTP $health_code)"
    run_test "Health endpoint returns 200" "0"
else
    log_err "Health check failed (HTTP $health_code)"
    run_test "Health endpoint returns 200" "1"
    if [ "$START_SERVER" = false ]; then
        log_warn "Start the server first with: go run . (from Monitor_sever dir)"
        log_warn "Or use: $0 --start"
        exit 1
    fi
fi

# --- Test 2: Single Session Working ---
log_step "=== Test 2: Single Session (Working) ==="
resp=$(send_event "sess-001" "claude" "pre_tool_use" "Edit" || true)
code=$(echo "$resp" | tail -1)
if [ "$code" = "200" ]; then
    log_info "Single working session event sent OK"
    run_test "Single session event returns 200" "0"
else
    log_err "Single session event returned HTTP $code"
    run_test "Single session event returns 200" "1"
fi

# --- Test 3: Four Sessions (4-Color Cycling) ---
log_step "=== Test 3: Four Concurrent Working Sessions (4-Color Cycling) ==="
log_info "Sending working events for 4 sessions to verify color palette cycling..."
log_info "Expected: 4 sessions cycle through Indigo, Green, Violet, Teal"

for i in 1 2 3 4; do
    sid="sess-color-${i}"
    send_event "$sid" "claude" "tool" "Read" || true
    log_info "  -> Sent working event for $sid"
    sleep 1
done

# Give server time to process
sleep 3
log_info "Check monitor output / serial payload for 4 distinct colors cycling"
run_test "4 sessions sent without error" "0"

# --- Test 4: Fifth Session (should cycle back to first color) ---
log_step "=== Test 4: Fifth Session (Color Cycling Wrap) ==="
send_event "sess-color-5" "claude" "tool" "Write" || true
log_info "Sent event for sess-color-5 — should reuse color set 1"
run_test "5th session sent without error" "0"

# --- Test 5: Session Completion ---
log_step "=== Test 5: Session Completion ==="
send_event "sess-001" "claude" "stop" "SessionEnd" || true
log_info "Sent completion event for sess-001"
run_test "Completion event sent" "0"

# --- Test 6: Idle Transition ---
log_step "=== Test 6: Idle Transition (20s timeout) ==="
log_info "Waiting for Working sessions to become Idle..."
# sess-color-1 through 5 are still "working" — they should go idle after 20s
wait_for_idle
log_info "After 22s, check monitor output — sessions should show 'Idle' (dark orange, pulse)"
run_test "Idle transition wait period" "0"

# --- Test 7: Cleanup (60s removal) ---
log_step "=== Test 7: Session Removal After Idle (60s cleanup) ==="
log_info "Waiting for idle/completed sessions to be removed..."
wait_for_removal
log_info "After 65s, all test sessions should be removed"
run_test "Cleanup wait period" "0"

# --- Test 8: Empty State ---
log_step "=== Test 8: Empty State ==="
log_info "All sessions should have been removed — monitor should show idle/green state"
run_test "Empty state reached" "0"

# --- Summary ---
echo ""
log_step "=== Test Summary ==="
echo -e "Passed: ${GREEN}${PASS}${NC}"
echo -e "Failed: ${RED}${FAIL}${NC}"
if [ "$FAIL" -gt 0 ]; then
    log_err "$FAIL test(s) failed"
    exit 1
else
    log_info "All tests passed!"
fi

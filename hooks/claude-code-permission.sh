#!/usr/bin/env bash
#
# Claude Code PreToolUse hook → watch-control bridge.
#
# Reads the PreToolUse JSON from stdin, POSTs it to the bridge's
# /hooks/permission endpoint, and prints the bridge's response on stdout
# unchanged. The bridge already returns the current Claude Code spec
# (hookSpecificOutput.permissionDecision), so this script is a thin pipe.
#
# Configure in ~/.claude/settings.json:
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "Bash|Edit|Write|MultiEdit",
#           "hooks": [
#             {
#               "type": "command",
#               "command": "/opt/watchcontrol/hooks/claude-code-permission.sh",
#               "timeout": 600
#             }
#           ]
#         }
#       ]
#     }
#   }
#
# Override the bridge URL with WATCHCONTROL_BRIDGE_URL if it's not on the
# default localhost:7860.

set -euo pipefail

BRIDGE_URL="${WATCHCONTROL_BRIDGE_URL:-http://127.0.0.1:7860}"
ENDPOINT="${BRIDGE_URL}/hooks/permission"

# Read the PreToolUse payload from stdin into memory. Claude Code sends it
# as a single JSON object.
input="$(cat)"

find_agent_ancestor_pid() {
  local pid="${PPID}"
  local line ppid comm args

  while [[ -n "${pid}" && "${pid}" != "0" ]]; do
    line="$(ps -o ppid= -o comm= -o args= -p "${pid}" 2>/dev/null || true)"
    [[ -z "${line}" ]] && break

    read -r ppid comm args <<<"${line}"
    if [[ "${comm}" == "claude" || "${comm}" == "codex" || " ${args} " =~ [[:space:]][^[:space:]]*/?(claude|codex)([[:space:]]|$) ]]; then
      printf '%s\n' "${pid}"
      return 0
    fi
    pid="${ppid}"
  done
}

agent_pid="$(find_agent_ancestor_pid || true)"
hook_pid="$$"

input="$(
  printf '%s' "${input}" | WATCHCONTROL_HOOK_PID="${hook_pid}" WATCHCONTROL_HOOK_AGENT_PID="${agent_pid}" node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(0, "utf8");
    const payload = JSON.parse(raw);
    payload.watchcontrol_hook = {
      hook_pid: process.env.WATCHCONTROL_HOOK_PID || null,
      agent_pid: process.env.WATCHCONTROL_HOOK_AGENT_PID || null,
    };
    process.stdout.write(JSON.stringify(payload));
  '
)"

# POST it to the bridge. The bridge blocks until the watch (or iPhone)
# responds, then returns a JSON object whose top-level
# hookSpecificOutput.permissionDecision is "allow" or "deny".
#
# --max-time matches the bridge-side PERMISSION_TIMEOUT_MS (10 minutes,
# 600s). If curl can't reach the bridge at all, fall back to "ask" so the
# user gets the interactive prompt instead of being silently blocked.
if response="$(curl --silent --fail \
                    --max-time 600 \
                    -H 'Content-Type: application/json' \
                    -X POST \
                    --data "${input}" \
                    "${ENDPOINT}" 2>/dev/null)"; then
  printf '%s\n' "${response}"
  exit 0
else
  curl_status=$?
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"watch-control bridge unreachable at %s (curl exit %d)"}}\n' \
    "${ENDPOINT}" "${curl_status}"
  exit 0
fi

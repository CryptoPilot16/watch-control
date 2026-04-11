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

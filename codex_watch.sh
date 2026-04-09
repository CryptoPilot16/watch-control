#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

: "${PUSHOVER_APP_TOKEN:?Missing PUSHOVER_APP_TOKEN}"
: "${PUSHOVER_USER_KEY:?Missing PUSHOVER_USER_KEY}"
: "${APPROVE_SECRET:?Missing APPROVE_SECRET}"

TMUX_SESSION="${TMUX_SESSION:-codex:0.0}"
TMUX_TARGETS="${TMUX_TARGETS:-$TMUX_SESSION}"
CODEX_APPROVE_KEY="${CODEX_APPROVE_KEY:-y}"
CLAUDE_APPROVE_KEY="${CLAUDE_APPROVE_KEY:-1}"
DEFAULT_APPROVE_KEY="${DEFAULT_APPROVE_KEY:-$CODEX_APPROVE_KEY}"
CODEX_DETECT_REGEX="${CODEX_DETECT_REGEX:-Would you like to run|Press enter to confirm|Yes, proceed|codex|openai}"
CLAUDE_DETECT_REGEX="${CLAUDE_DETECT_REGEX:-claude|anthropic|press[[:space:]]+1|option[[:space:]]+1|(^|[[:space:][:punct:]])1[.)][[:space:]]*(approve|allow|continue|yes)}"
APPROVE_PORT="${APPROVE_PORT:-8787}"
APPROVE_HOST="${APPROVE_HOST:-127.0.0.1}"
APPROVE_URL="${APPROVE_URL:-http://${APPROVE_HOST}:${APPROVE_PORT}/approve}"
LOG_FILE="${CODEX_WATCH_LOG:-/tmp/codex_watch.log}"
APPROVAL_QUEUE_FILE="${APPROVAL_QUEUE_FILE:-/tmp/codex_approval_queue.tsv}"
APPROVAL_QUEUE_LOCK="${APPROVAL_QUEUE_LOCK:-/tmp/codex_approval_queue.lock}"
APPROVAL_PROMPT_REGEX="${APPROVAL_PROMPT_REGEX:-Would you like to run|Press enter to confirm|Yes, proceed|Do you want to proceed|Approve this command|Allow this command|Run this command|Continue\?}"

# Ensure approval link carries secret for webhook auth.
if [[ "$APPROVE_URL" != *"secret="* ]]; then
  if [[ "$APPROVE_URL" == *"?"* ]]; then
    APPROVE_URL="${APPROVE_URL}&secret=${APPROVE_SECRET}"
  else
    APPROVE_URL="${APPROVE_URL}?secret=${APPROVE_SECRET}"
  fi
fi

# Prevent spamming every 2 seconds.
LAST_SENT_FILE="${LAST_SENT_FILE:-/tmp/codex_approval_last_sent}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-30}"

now_ts() { date +%s; }

read -r -a TARGETS <<< "$TMUX_TARGETS"
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  TARGETS=("$TMUX_SESSION")
fi

detect_key_from_pane() {
  local pane="$1"
  local key="$DEFAULT_APPROVE_KEY"
  local detected="default"

  if echo "$pane" | grep -Eqi "$CLAUDE_DETECT_REGEX"; then
    key="$CLAUDE_APPROVE_KEY"
    detected="claude"
  elif echo "$pane" | grep -Eqi "$CODEX_DETECT_REGEX"; then
    key="$CODEX_APPROVE_KEY"
    detected="codex"
  fi

  if [[ -z "$key" ]]; then
    key="$DEFAULT_APPROVE_KEY"
  fi

  printf '%s\t%s\n' "$key" "$detected"
}

queue_depth() {
  (
    flock -x 9
    if [[ -f "$APPROVAL_QUEUE_FILE" ]]; then
      grep -cve '^[[:space:]]*$' "$APPROVAL_QUEUE_FILE" || true
    else
      echo "0"
    fi
  ) 9>>"$APPROVAL_QUEUE_LOCK"
}

enqueue_request() {
  local target="$1"
  local approve_key="$2"
  local ts seq
  ts="$(now_ts)"
  seq="${ts}.$RANDOM"

  (
    flock -x 9
    printf '%s\t%s\t%s\t%s\n' "$ts" "$seq" "$target" "$approve_key" >> "$APPROVAL_QUEUE_FILE"
  ) 9>>"$APPROVAL_QUEUE_LOCK"
}

should_send() {
  if [[ -f "$LAST_SENT_FILE" ]]; then
    local last
    last=$(cat "$LAST_SENT_FILE" || echo 0)
    (( $(now_ts) - last >= COOLDOWN_SECONDS ))
  else
    return 0
  fi
}

send_push() {
  local message="$1"
  local resp
  resp=$(curl -s \
    -F "token=$PUSHOVER_APP_TOKEN" \
    -F "user=$PUSHOVER_USER_KEY" \
    -F "title=AI Approval Needed" \
    -F "message=$message" \
    -F "url=$APPROVE_URL" \
    -F "url_title=Approve next" \
    https://api.pushover.net/1/messages.json)

  echo "$(date) pushover_resp=$resp" >> "$LOG_FILE"
}

declare -A IN_PROMPT=()

while true; do
  for target in "${TARGETS[@]}"; do
    in_prompt="${IN_PROMPT[$target]:-0}"

    pane="$(tmux capture-pane -pt "$target" -S -200 2>/dev/null || true)"

    if echo "$pane" | grep -Eqi "$APPROVAL_PROMPT_REGEX"; then
      if [[ "$in_prompt" -eq 0 ]]; then
        IFS=$'\t' read -r approve_key detected_model <<< "$(detect_key_from_pane "$pane")"
        enqueue_request "$target" "$approve_key"
        depth="$(queue_depth)"
        echo "$(date) queued target=$target key=$approve_key model=$detected_model depth=$depth" >> "$LOG_FILE"
        if should_send; then
          send_push "Tap Approve next (queue: $depth, newest: $target)" || echo "$(date) send_push failed" >> "$LOG_FILE"
          now_ts > "$LAST_SENT_FILE"
        fi
      fi
      IN_PROMPT["$target"]=1
    else
      IN_PROMPT["$target"]=0
    fi
  done

  sleep 2
done

#!/usr/bin/env bash

if [ -n "${SWARM_ENV_SH_LOADED:-}" ]; then
  return 0
fi
SWARM_ENV_SH_LOADED=1

SWARM_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SWARM_REPO_ROOT:=$(cd "$SWARM_BIN_DIR/../.." && pwd)}"
: "${SWARM_PROTOCOL_ROOT:=$SWARM_REPO_ROOT/swarm}"
: "${SWARM_RUNTIME_ROOT:=/tmp/claude-swarm}"
: "${SWARM_PROMPTS_DIR:=$SWARM_PROTOCOL_ROOT/prompts}"
: "${SWARM_LOG_DIR:=$SWARM_RUNTIME_ROOT/logs}"
: "${SWARM_RUNTIME_DIR:=$SWARM_RUNTIME_ROOT/runtime}"

swarm_tmux_display() {
  local format="$1"
  local target="${SWARM_PANE_ID:-${TMUX_PANE:-}}"

  if [ -n "$target" ]; then
    tmux display-message -p -t "$target" "$format"
  else
    tmux display-message -p "$format"
  fi
}

swarm_require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required" >&2
    return 1
  fi

  if [ -z "${TMUX:-}" ]; then
    echo "This command must run inside tmux" >&2
    return 1
  fi
}

swarm_session() {
  swarm_tmux_display '#S'
}

swarm_window() {
  swarm_tmux_display '#W'
}

swarm_pane_path() {
  swarm_tmux_display '#{pane_current_path}'
}

swarm_has_orchestrator() {
  local session="$1"

  tmux list-windows -t "$session" -F '#W' | grep -cE '^orchestrator(-|$)' || true
}

swarm_inbox_dir() {
  local session="$1"
  local identity="$2"

  printf '%s/inbox/%s/%s' "$SWARM_RUNTIME_ROOT" "$session" "$identity"
}

swarm_runtime_session_dir() {
  local session="$1"

  printf '%s/%s' "$SWARM_RUNTIME_DIR" "$session"
}

swarm_message_file() {
  local session="$1"
  local recipient="$2"
  local sender="$3"

  printf '%s/%s.msg' "$(swarm_inbox_dir "$session" "$recipient")" "$sender"
}

swarm_orchestrator_window_name() {
  local session="$1"

  tmux list-windows -t "$session" -F '#W' | grep -m 1 -E '^orchestrator(-|$)' || true
}

swarm_ensure_runtime() {
  local session="$1"

  mkdir -p \
    "$SWARM_LOG_DIR" \
    "$SWARM_RUNTIME_DIR" \
    "$(swarm_runtime_session_dir "$session")" \
    "$SWARM_RUNTIME_ROOT/inbox/$session/orchestrator"
}

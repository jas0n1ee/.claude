#!/bin/bash
# Soft error mode: log failures but never abort — Claude must always see output
set -uo pipefail
[ -z "${TMUX:-}" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../swarm/bin/swarm-env.sh
. "$SCRIPT_DIR/../swarm/bin/swarm-env.sh"

SWARM_PANE_ID="$(tmux display-message -p '#D' 2>/dev/null || true)"
export SWARM_PANE_ID

SESSION="$(swarm_session 2>/dev/null || true)"
CURRENT_WINDOW="$(swarm_window 2>/dev/null || true)"

# Guard: if we can't determine session/window, skip swarm logic silently
if [ -z "$SESSION" ] || [ -z "$CURRENT_WINDOW" ]; then
  exit 0
fi

HAS_ORCHESTRATOR="$(swarm_has_orchestrator "$SESSION" 2>/dev/null || echo 0)"

if [ "$HAS_ORCHESTRATOR" = "0" ]; then
  # Use pane ID as target to avoid tmux misparse of dotted window names (e.g. "2.1.97")
  tmux rename-window -t "$SWARM_PANE_ID" orchestrator 2>/dev/null || true
  IDENTITY="orchestrator"
elif [ "$CURRENT_WINDOW" = "orchestrator" ]; then
  IDENTITY="orchestrator"
else
  IDENTITY="$CURRENT_WINDOW"
fi

# ─── Emit imperative swarm boot directive ────────────────────────────────────
#
# This output is injected as a system message into Claude's context.
# It must be imperative (not descriptive) so Claude treats it as instructions,
# not just informational metadata.

SWARM_ROLE_UPPER=$([ "$IDENTITY" = "orchestrator" ] && echo "ORCHESTRATOR" || echo "WORKER")

echo "╔══════════════════════════════════════════════╗"
echo "║       SWARM MODE ACTIVE — ACTION REQUIRED    ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "你的角色：${SWARM_ROLE_UPPER}（identity: ${IDENTITY}，session: ${SESSION}）"
echo ""
echo "以下是你必须立即遵守的行为规范（优先于处理任何用户消息）："
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$IDENTITY" = "orchestrator" ]; then
  cat "$SCRIPT_DIR/../swarm/orchestrator.md"
else
  cat "$SCRIPT_DIR/../swarm/worker.md"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Deliver unread inbox messages ───────────────────────────────────────────
swarm_ensure_runtime "$SESSION" 2>/dev/null || true
INBOX_DIR="$(swarm_inbox_dir "$SESSION" "$IDENTITY")"
if [ -d "$INBOX_DIR" ]; then
  shopt -s nullglob
  FILES=("$INBOX_DIR"/*.msg)
  shopt -u nullglob
  if [ "${#FILES[@]}" -gt 0 ]; then
    echo ""
    echo "=== UNREAD INBOX MESSAGES ==="
    for f in "${FILES[@]}"; do
      SENDER=$(basename "$f" .msg)
      echo "[from ${SENDER}] $(cat "$f")"
    done
    echo ""
    echo "Mark as read: rm ${INBOX_DIR}/<sender>.msg"
    echo "============================="
  fi
fi

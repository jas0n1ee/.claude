#!/bin/bash
[ -z "$TMUX" ] && exit 0

SESSION=$(tmux display-message -p '#S' -t "$TMUX_PANE")
CURRENT_WINDOW=$(tmux display-message -p '#W' -t "$TMUX_PANE")
HAS_ORCHESTRATOR=$(tmux list-windows -t "$SESSION" -F '#W' | grep -c '^orchestrator$')

if [ "$HAS_ORCHESTRATOR" = "0" ]; then
  tmux rename-window -t "$SESSION:$CURRENT_WINDOW" orchestrator
  echo "SWARM_ROLE=orchestrator (just promoted, window renamed)"
  IDENTITY="orchestrator"
elif [ "$CURRENT_WINDOW" = "orchestrator" ]; then
  IDENTITY="orchestrator"
else
  echo "SWARM_ROLE=worker IDENTITY=$CURRENT_WINDOW"
  IDENTITY="$CURRENT_WINDOW"
fi

# 启动时自动投递 inbox 中的未读消息（双向）
INBOX_DIR="$HOME/.claude/swarm/.inbox/$SESSION/$IDENTITY"
if [ -d "$INBOX_DIR" ]; then
  PENDING=$(ls "$INBOX_DIR"/*.msg 2>/dev/null)
  if [ -n "$PENDING" ]; then
    echo ""
    echo "=== UNREAD INBOX MESSAGES ==="
    for f in "$INBOX_DIR"/*.msg; do
      [ -f "$f" ] || continue
      SENDER=$(basename "$f" .msg)
      echo "[from ${SENDER}] $(cat "$f")"
    done
    echo ""
    echo "Mark as read: rm ~/.claude/swarm/.inbox/${SESSION}/${IDENTITY}/<sender>.msg"
    echo "============================="
  fi
fi

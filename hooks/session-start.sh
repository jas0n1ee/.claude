#!/bin/bash
[ -z "$TMUX" ] && exit 0

SESSION=$(tmux display-message -p '#S')
CURRENT_WINDOW=$(tmux display-message -p '#W')
HAS_ORCHESTRATOR=$(tmux list-windows -t "$SESSION" -F '#W' | grep -c '^orchestrator$')

if [ "$HAS_ORCHESTRATOR" = "0" ]; then
  tmux rename-window -t "$SESSION:$CURRENT_WINDOW" orchestrator
  echo "SWARM_ROLE=orchestrator (just promoted, window renamed)"
else
  echo "SWARM_ROLE=worker IDENTITY=$CURRENT_WINDOW"
fi
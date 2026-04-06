#!/bin/bash
[ -z "$TMUX" ] && exit 0

CURRENT_WINDOW=$(tmux display-message -p '#W')
CURRENT_SESSION=$(tmux display-message -p '#S')

if [ "$CURRENT_WINDOW" = "orchestrator" ]; then
  exit 0
fi

# 从 stdin 读取 hook 输入，直接取 last_assistant_message
INPUT=$(cat)
LAST_MESSAGE=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('last_assistant_message', ''))
")

TASK_DONE=$(echo "$LAST_MESSAGE" | grep "^TASK_DONE:" | tail -1)
STATUS=$(echo "$LAST_MESSAGE" | grep "^STATUS:" | tail -1)
NEXT_INFO=$(echo "$LAST_MESSAGE" | grep "^NEXT_NEEDED:" | tail -1)

if [ -n "$TASK_DONE" ]; then
  SUMMARY="$TASK_DONE | $STATUS | $NEXT_INFO"
else
  SUMMARY="TASK_DONE: (unstructured) $(echo "$LAST_MESSAGE" | tail -3 | tr '\n' ' ' | cut -c1-200)"
fi

tmux send-keys -t "${CURRENT_SESSION}:orchestrator.0" "[${CURRENT_WINDOW}] ${SUMMARY}" Enter
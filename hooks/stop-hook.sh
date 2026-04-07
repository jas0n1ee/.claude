#!/bin/bash
[ -z "$TMUX" ] && exit 0

# 用 $TMUX_PANE（继承自启动 Claude 的 shell，稳定）查询当前 pane 所属窗口
# 不带 -t 时 tmux display-message 返回客户端当前活跃窗口，会随用户切换而变化
CURRENT_WINDOW=$(tmux display-message -p '#W' -t "$TMUX_PANE")
CURRENT_SESSION=$(tmux display-message -p '#S' -t "$TMUX_PANE")
LOG_DIR="$HOME/.claude/swarm/.logs"
LOG_FILE="$LOG_DIR/stop-hook.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR"

log() {
  echo "[$TS][$CURRENT_SESSION:$CURRENT_WINDOW] $*" >> "$LOG_FILE"
}

if [ "$CURRENT_WINDOW" = "orchestrator" ]; then
  exit 0
fi

# 如果 orchestrator 窗口不存在，跳过汇报
HAS_ORCHESTRATOR=$(tmux list-windows -t "$CURRENT_SESSION" -F '#W' | grep -c '^orchestrator$' || true)
if [ "$HAS_ORCHESTRATOR" = "0" ]; then
  log "SKIP: no orchestrator window in session"
  exit 0
fi

# 从 stdin 读取 hook 输入
INPUT=$(cat)
LAST_MESSAGE=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('last_assistant_message', ''))
")

TASK_DONE=$(echo "$LAST_MESSAGE" | grep "^TASK_DONE:" | tail -1)
STATUS=$(echo "$LAST_MESSAGE" | grep "^STATUS:" | tail -1)
NEXT_INFO=$(echo "$LAST_MESSAGE" | grep "^NEXT_NEEDED:" | tail -1)

if [ -z "$TASK_DONE" ]; then
  # 没有结构化 TASK_DONE，说明 worker 还在执行中间步骤，静默退出
  # stop hook 在每次 Claude 响应结束时都触发，不只是 session 结束
  exit 0
fi

SUMMARY="$TASK_DONE | $STATUS | $NEXT_INFO"

# 主 channel：写入 orchestrator inbox（worker → orchestrator 方向）
INBOX_FILE="$HOME/.claude/swarm/.inbox/$CURRENT_SESSION/orchestrator/${CURRENT_WINDOW}.msg"
mkdir -p "$(dirname "$INBOX_FILE")"
echo "$SUMMARY" > "$INBOX_FILE"
log "INBOX WRITE: $INBOX_FILE"

# 次 channel：tmux 推送通知（best-effort）
if tmux send-keys -t "${CURRENT_SESSION}:orchestrator.0" "[${CURRENT_WINDOW}] ${SUMMARY}" Enter 2>>"$LOG_FILE"; then
  log "NOTIFY OK"
else
  log "NOTIFY FAILED (message still in inbox)"
fi

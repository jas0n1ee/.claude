#!/bin/bash
set -euo pipefail
[ -z "${TMUX:-}" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../swarm/bin/swarm-env.sh
. "$SCRIPT_DIR/../swarm/bin/swarm-env.sh"

SWARM_PANE_ID="$(tmux display-message -p '#D')"
export SWARM_PANE_ID

# 通过 pane 归属的窗口和 session 判断身份，避免随用户切换窗口漂移
CURRENT_WINDOW="$(swarm_window)"
CURRENT_SESSION="$(swarm_session)"
LOG_DIR="$SWARM_LOG_DIR"
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
HAS_ORCHESTRATOR="$(swarm_has_orchestrator "$CURRENT_SESSION")"
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

# SUMMARY = worker 的最后一条完整消息
# stop hook 在 Claude 等待 human input 时触发，这里直接传递完整原始消息
SUMMARY="$LAST_MESSAGE"

# 主 channel：写入 orchestrator inbox（worker → orchestrator 方向）
# 使用 /tmp 避免 .claude 目录的敏感文件权限拦截
swarm_ensure_runtime "$CURRENT_SESSION"
INBOX_FILE="$(swarm_message_file "$CURRENT_SESSION" "orchestrator" "$CURRENT_WINDOW")"
mkdir -p "$(dirname "$INBOX_FILE")"
echo "$SUMMARY" > "$INBOX_FILE"
log "INBOX WRITE: $INBOX_FILE"

# 次 channel：tmux 推送通知（best-effort）
if tmux send-keys -t "${CURRENT_SESSION}:orchestrator.0" "[${CURRENT_WINDOW}] ${SUMMARY}" Enter 2>>"$LOG_FILE"; then
  log "NOTIFY OK"
else
  log "NOTIFY FAILED (message still in inbox)"
fi

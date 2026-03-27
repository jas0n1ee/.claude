#!/usr/bin/env bash
set -euo pipefail

: "${OPENCLAW_NOTIFY_URL:?OPENCLAW_NOTIFY_URL is required}"
: "${OPENCLAW_NOTIFY_TOKEN:?OPENCLAW_NOTIFY_TOKEN is required}"

NODE_NAME="$(hostname -s 2>/dev/null || hostname || echo unknown-node)"
TMUX_SESSION=""
TMUX_PANE=""
TASK_ID="${OPENCLAW_TASK_ID:-}"
SUMMARY="${OPENCLAW_SUMMARY:-}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
  TMUX_PANE="$(tmux display-message -p '#{window_index}.#{pane_index}' 2>/dev/null || true)"
fi

if [ -z "$TMUX_SESSION" ]; then
  TMUX_SESSION="${OPENCLAW_TMUX_SESSION:-unknown-session}"
fi

if [ -z "$TMUX_PANE" ]; then
  TMUX_PANE="${OPENCLAW_TMUX_PANE:-unknown-pane}"
fi

JSON_PAYLOAD="$(python3 - <<'PY' "$NODE_NAME" "$TMUX_SESSION" "$TMUX_PANE" "$TASK_ID" "$SUMMARY" "$TS"
import json, sys
node, tmux_session, tmux_pane, task_id, summary, ts = sys.argv[1:7]
payload = {
    "event": "claude_stop",
    "version": "v1",
    "node": node,
    "tmuxSession": tmux_session,
    "tmuxPane": tmux_pane,
    "ts": ts,
}
if task_id:
    payload["taskId"] = task_id
if summary:
    payload["summary"] = summary
print(json.dumps(payload, ensure_ascii=False))
PY
)"

curl -fsS -X POST "$OPENCLAW_NOTIFY_URL/notify/claude-stop" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENCLAW_NOTIFY_TOKEN" \
  --data "$JSON_PAYLOAD"


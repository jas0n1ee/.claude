#!/usr/bin/env bash
set -euo pipefail

: "${OPENCLAW_HOOKS_URL:?OPENCLAW_HOOKS_URL is required}"
: "${OPENCLAW_HOOKS_TOKEN:?OPENCLAW_HOOKS_TOKEN is required}"
: "${OPENCLAW_HOOKS_TO:?OPENCLAW_HOOKS_TO is required}"

NODE_NAME="$(hostname -s 2>/dev/null || hostname || echo unknown-node)"
TMUX_SESSION=""
TMUX_PANE=""
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

MESSAGE_PAYLOAD="$(python3 - <<'PY' "$NODE_NAME" "$TMUX_SESSION" "$TMUX_PANE" "$TS"
import json, sys
node, tmux_session, tmux_pane, ts = sys.argv[1:5]
message = "\n".join([
    "Claude Code stop event",
    f"node={node}",
    f"tmux_session={tmux_session}",
    f"tmux_pane={tmux_pane}",
    f"ts={ts}",
])
payload = {
    "message": message,
    "wakeMode": "now",
    "deliver": True,
    "channel": "telegram",
    "to": node and None,
}
print(json.dumps(payload, ensure_ascii=False))
PY
)"

MESSAGE_PAYLOAD="$(python3 - <<'PY' "$MESSAGE_PAYLOAD" "$OPENCLAW_HOOKS_TO"
import json, sys
payload = json.loads(sys.argv[1])
payload['to'] = sys.argv[2]
print(json.dumps(payload, ensure_ascii=False))
PY
)"

curl -fsS -X POST "$OPENCLAW_HOOKS_URL/hooks/agent" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENCLAW_HOOKS_TOKEN" \
  --data "$MESSAGE_PAYLOAD"

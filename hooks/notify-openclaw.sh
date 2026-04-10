#!/usr/bin/env bash
set -euo pipefail

: "${OPENCLAW_HOOKS_URL:?OPENCLAW_HOOKS_URL is required}"
: "${OPENCLAW_HOOKS_TOKEN:?OPENCLAW_HOOKS_TOKEN is required}"
: "${OPENCLAW_HOOKS_TO:?OPENCLAW_HOOKS_TO is required}"

NODE_NAME="$(hostname -s 2>/dev/null || hostname || echo unknown-node)"
TMUX_SESSION=""
TMUX_WINDOW=""
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
  TMUX_WINDOW="$(tmux display-message -p '#W' 2>/dev/null || true)"
fi

if [ -z "$TMUX_SESSION" ]; then
  TMUX_SESSION="${OPENCLAW_TMUX_SESSION:-unknown-session}"
fi

if [ -z "$TMUX_WINDOW" ]; then
  TMUX_WINDOW="${OPENCLAW_TMUX_WINDOW:-unknown-window}"
fi

MESSAGE_PAYLOAD="$(python3 - <<'PY' "$NODE_NAME" "$TMUX_SESSION" "$TMUX_WINDOW" "$TS" "${CLAUDE_LAST_MESSAGE:-}"
import json, sys, os
node, tmux_session, tmux_window, ts, claude_msg = sys.argv[1:6]

# Check if NOTIFY HUMAN signal is in the message
is_notify_human = "NOTIFY HUMAN" in claude_msg if claude_msg else False

# Build message content
lines = [
    "Claude Code stop event",
    f"node={node}",
    f"tmux_session={tmux_session}",
    f"tmux_window={tmux_window}",
    f"ts={ts}",
]

# Add NOTIFY HUMAN indicator and message content
if is_notify_human:
    lines.append("signal=NOTIFY HUMAN")
    if claude_msg.strip():
        # Truncate message to avoid oversized payloads
        msg_preview = claude_msg.strip()[:500]
        if len(claude_msg.strip()) > 500:
            msg_preview += "..."
        lines.append("---")
        lines.append("Message preview:")
        lines.append(msg_preview)
else:
    # Regular stop without NOTIFY HUMAN - do nothing
    print(json.dumps({"skip": True}))
    sys.exit(0)

message = "\n".join(lines)

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

# Check if we should skip (regular stop without NOTIFY HUMAN)
if echo "$MESSAGE_PAYLOAD" | grep -q '"skip": true'; then
    exit 0
fi

MESSAGE_PAYLOAD="$(python3 - <<'PY' "$MESSAGE_PAYLOAD" "$OPENCLAW_HOOKS_TO"
import json, sys
payload = json.loads(sys.argv[1])
payload['to'] = sys.argv[2]
print(json.dumps(payload, ensure_ascii=False))
PY
)"

# Build curl command with optional proxy
CURL_OPTS="-fsS"
if [ -n "${TS_PROXY:-}" ]; then
    CURL_OPTS="$CURL_OPTS --proxy $TS_PROXY"
fi

curl $CURL_OPTS -X POST "$OPENCLAW_HOOKS_URL/hooks/agent" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENCLAW_HOOKS_TOKEN" \
  --data "$MESSAGE_PAYLOAD"

# Swarm Protocol

This repo uses a shared Swarm layout so Claude Code and Codex can participate in the same workflow.

## Layout

- Versioned protocol, prompts, and scripts live in `swarm/`
- The repo root should be referenced through `SWARM_REPO_ROOT` in scripts and prompts instead of hardcoded home-directory paths
- Runtime state lives outside the repo by default in `/tmp/claude-swarm`
- Legacy `swarm/.inbox/` and `swarm/.logs/` paths should not be used for new runtime state

## Runtime directories

```text
/tmp/claude-swarm/
  inbox/
    <session>/
      orchestrator/
      <worker-name>/
  logs/
  runtime/
```

`SWARM_RUNTIME_ROOT` may be set to override `/tmp/claude-swarm`.

## Messaging model

- The inbox is the reliable transport.
- tmux `send-keys` is a best-effort notification channel.
- Claude workers write their final full assistant message into `inbox/<session>/orchestrator/<worker>.msg`.
- Orchestrators write task messages into `inbox/<session>/<worker>/orchestrator.msg`.

## Shared scripts

- `swarm/bin/swarm-bootstrap-codex`: start Codex as orchestrator in the current tmux session
- `swarm/bin/swarm-spawn-claude-worker`: create a Claude worker window and send its initial task
- `swarm/bin/swarm-send`: write a message to a Swarm inbox and optionally notify over tmux
- `swarm/bin/swarm-read`: print unread inbox messages for an identity
- `swarm/bin/swarm-ack`: remove an inbox message after it has been handled
- `swarm/bin/swarm-ping-orchestrator`: wake the current session's orchestrator by sending a prompt to its existing tmux pane

## Claude integration

- `hooks/session-start.sh` reads unread inbox messages from `SWARM_RUNTIME_ROOT/inbox/...`
- `hooks/stop-hook.sh` writes worker full-message summaries into `SWARM_RUNTIME_ROOT/inbox/...`

## Codex integration

- Codex does not rely on stop hooks in this workflow.
- Codex joins the shared protocol through `swarm/bin/swarm-bootstrap-codex`.
- The bootstrap prompt is `swarm/prompts/codex-orchestrator.md`.

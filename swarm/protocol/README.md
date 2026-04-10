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
  logs/
  runtime/
```

`SWARM_RUNTIME_ROOT` may be set to override `/tmp/claude-swarm`.

## Messaging model

- Current transport is tmux-window messaging driven by `swarm.py`.
- Claude workers deliver their final full assistant message directly into the orchestrator tmux pane from the stop hook.
- Orchestrators assign or revise worker tasks by sending tmux input through `swarm.py send`.
- Legacy inbox files may still exist on disk from older experiments, but they are not part of the active protocol.

## Known failure mode: shell-expanded task payloads

When an orchestrator invokes `swarm.py spawn` or `swarm.py send` through a shell command, the task text must reach `swarm.py` as a literal argument.

- Unsafe example: embedding a Markdown code span like `` `brew update` `` inside the outer shell command
- Failure mode: the local shell may execute the backticked command before `swarm.py` runs
- Symptoms: the orchestrator machine starts the command locally, the worker receives damaged task text, and later retries may block on locks or other side effects from the unintended local process
- Safe default: keep task text plain, for example `Run brew update. Do not install, upgrade, or uninstall packages.`
- If literal shell syntax is required in task text, escape it for the local shell first or use another transport that preserves the argument verbatim

## Shared scripts

- `swarm/swarm.py`: canonical CLI for Claude-side session start, worker spawn/send/kill, ping, and stop-hook delivery
- `swarm/bin/codex-orchestrator`: start Codex as the orchestrator in the current tmux window
- `swarm/bin/codex-shell-integration.zsh`: optional shell wrapper that enables `codex orchestrator`

## Claude integration

- `hooks/session-start.sh` calls `python3 ~/.claude/swarm/swarm.py session-start`
- `hooks/stop-hook.sh` calls `python3 ~/.claude/swarm/swarm.py stop-hook`

## Codex integration

- Codex does not rely on stop hooks in this workflow.
- Codex joins the shared protocol through `swarm/bin/codex-orchestrator`.
- The bootstrap prompt is `swarm/prompts/codex-orchestrator.md`.
- `swarm/bin/codex-orchestrator` performs tmux/session/window verification itself and injects an initial `swarm.py status` snapshot so Codex can start working immediately instead of spending its first turn on bootstrap rituals.
- If you want the exact shell syntax `codex orchestrator`, source `swarm/bin/codex-shell-integration.zsh` from your shell rc.

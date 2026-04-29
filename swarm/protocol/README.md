# Swarm Protocol

This repo uses a shared Swarm layout so Claude Code and Codex can participate in the same workflow.

## Layout

- Versioned protocol, prompts, and scripts live in `swarm/`
- The repo root should be referenced through `SWARM_REPO_ROOT` in scripts and prompts instead of hardcoded home-directory paths
- Runtime state lives outside the repo by default in `/tmp/agent-swarm`
- Legacy `swarm/.inbox/` and `swarm/.logs/` paths should not be used for new runtime state

## Runtime directories

```text
/tmp/agent-swarm/
  logs/
  topics/<topic>/
    events.jsonl
    messages/
    workers/<worker>/
```

`SWARM_RUNTIME_ROOT` may be set to override `/tmp/agent-swarm`.

## Messaging model

- Current transport is tmux-window messaging driven by `swarm.py`.
- The tmux session name is the Swarm topic. The orchestrator window is named `orchestrator`; worker windows use explicit worker names.
- Orchestrators assign or revise worker tasks with `spawn --name ... --message|--prompt-file ...` or `send --name ... --message|--prompt-file ...`.
- Full task and result messages are persisted under runtime artifacts before tmux receives a short reference or notification.
- Claude workers deliver their final raw assistant message through `stop-hook`; Codex workers deliver round output through `worker-loop`.
- Worker -> Orchestrator tmux notifications are capped at 1000 characters by default. Longer messages are reported by artifact path.
- Legacy inbox files may still exist on disk from older experiments, but they are not part of the active protocol.

## Known failure mode: shell-expanded task payloads

When an orchestrator invokes `swarm.py spawn` or `swarm.py send` through a shell command, the task text must reach `swarm.py` as a literal argument.

- Unsafe example: embedding a Markdown code span like `` `brew update` `` inside the outer shell command
- Failure mode: the local shell may execute the backticked command before `swarm.py` runs
- Symptoms: the orchestrator machine starts the command locally, the worker receives damaged task text, and later retries may block on locks or other side effects from the unintended local process
- Safe default: keep task text plain, for example `Run brew update. Do not install, upgrade, or uninstall packages.`
- For long text, special characters, shell syntax, or audit-worthy tasks, use `--prompt-file`.

## Shared scripts

- `swarm/swarm.py`: canonical CLI for local orchestrator/worker coordination, worker spawn/send/kill, status/show/tail, ping, notes, session-start, stop-hook, and Codex worker-loop
- `swarm/bin/codex-orchestrator`: start Codex as the orchestrator in the current tmux window
- `swarm/bin/codex-shell-integration.zsh`: optional shell wrapper that enables `codex orchestrator`

## Claude integration

- `hooks/session-start.sh` calls `python3 ~/.claude/swarm/swarm.py session-start`
- `hooks/stop-hook.sh` calls `python3 ~/.claude/swarm/swarm.py stop-hook`
- `.claude/swarm/swarm.py` infers engine `claude` from its path and launches interactive workers with `claude --dangerously-skip-permissions`.

## Codex integration

- Codex does not rely on stop hooks in this workflow.
- `.codex/swarm/swarm.py` infers engine `codex` from its path and launches persistent worker-loop windows that run `codex exec --dangerously-bypass-approvals-and-sandbox` per queued task.
- Codex joins the shared protocol through `swarm/bin/codex-orchestrator`.
- The bootstrap prompt is `swarm/prompts/codex-orchestrator.md`.
- `swarm/bin/codex-orchestrator` performs tmux/session/window verification itself and injects an initial `swarm.py status` snapshot so Codex can start working immediately instead of spending its first turn on bootstrap rituals.
- If you want the exact shell syntax `codex orchestrator`, source `swarm/bin/codex-shell-integration.zsh` from your shell rc.

## Human and agent routing

- `swarm.py` coordinates only one local Swarm inside one tmux session.
- It does not route cross-agent or Feishu group messages.
- `NOTIFY HUMAN` remains a semantic trigger; this runtime records it as an artifact for a future notifier layer.
- Future Feishu Bot integration should consume runtime artifacts. Python integration can use the official `lark_oapi` SDK.

## File consistency

`.claude/swarm/swarm.py` and `.codex/swarm/swarm.py` are intentionally identical files. Keep them aligned by review; do not add a hash checker or automatic sync script.

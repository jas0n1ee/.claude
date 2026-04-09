---
id: 002
date: 2026-04-07
component: stop-hook
severity: medium
status: fixed
fix_commit: hooks/stop-hook.sh updated
---

## 现象

在只有 `claude-self-improving` 窗口、没有 `orchestrator` 窗口的 session 中，stop hook 报错：

```
Stop hook error: Failed with non-blocking status code: can't find window: orchestrator
```

## 原始输出 / 关键片段

```bash
# stop-hook.sh 原逻辑：
if [ "$CURRENT_WINDOW" = "orchestrator" ]; then
  exit 0
fi
# 直接发送，未检查 orchestrator 窗口是否存在
tmux send-keys -t "${CURRENT_SESSION}:orchestrator.0" "[${CURRENT_WINDOW}] ${SUMMARY}" Enter
```

## 根因分析

stop-hook 只跳过了"自己是 orchestrator"的情况，但未处理"orchestrator 窗口根本不存在"的情况。`claude-self-improving` 是一个独立角色，不属于 orchestrator/worker 对，没有 orchestrator 窗口可以汇报。

## 修复方案

在尝试发送前，先检查 orchestrator 窗口是否存在；不存在则直接 exit 0：

```bash
HAS_ORCHESTRATOR=$(tmux list-windows -t "$CURRENT_SESSION" -F '#W' | grep -c '^orchestrator$' || true)
if [ "$HAS_ORCHESTRATOR" = "0" ]; then
  exit 0
fi
```

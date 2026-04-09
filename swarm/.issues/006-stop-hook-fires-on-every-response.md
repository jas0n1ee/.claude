---
id: 006
date: 2026-04-07
component: stop-hook
severity: high
status: fixed
fix_commit: stop-hook.sh: 无 TASK_DONE 时静默退出，去掉 unstructured fallback
---

## 现象

orchestrator 在 2-3 分钟内收到 worker-impl 的 13 条 inbox 写入，全部是中间状态，
最终 inbox 内容为：`TASK_DONE: (unstructured) （停止响应，等用户。）`
worker 实际上还在运行（或已完成但未输出结构化 TASK_DONE）。

## 根因分析

Claude Code 的 Stop hook 在**每次 Claude 响应流结束时**触发，不只是 session 结束。
Worker 在执行任务过程中每完成一次 tool use 循环，hook 就触发一次。

旧代码中，未找到 `TASK_DONE:` 时有 unstructured fallback：
```bash
SUMMARY="TASK_DONE: (unstructured) $(echo "$LAST_MESSAGE" | tail -3 | tr '\n' ' ' | cut -c1-200)"
```

这导致每次中间响应都写入 inbox，orchestrator 收到大量噪音，
且最终写入的是 worker 最后一次中间响应的末尾内容，与实际任务状态无关。

## 修复方案

没有结构化 `TASK_DONE:` 的响应直接静默退出，不写 inbox，不发通知：

```bash
if [ -z "$TASK_DONE" ]; then
  exit 0
fi
```

**副作用**：worker 异常退出（无 TASK_DONE）时 orchestrator 不会收到通知。
这是可接受的权衡——inbox 只应包含有意义的完成信号，
异常情况由 human 或 orchestrator 通过其他方式介入（如日志、定期检查）。
Worker 规范已要求必须输出 TASK_DONE，不遵守规范的 worker 本身就需要修正。

---
id: 001
date: 2026-04-07
component: orchestrator
severity: medium
status: fixed
fix_commit: orchestrator.md + skill.md updated
---

## 现象

orchestrator 用 `tmux send-keys` 给 worker 发送长任务文本时，worker 终端显示 `[pasted text]` 并停住，不执行。需要 orchestrator 额外再发一次 Enter 才能触发。

## 原始输出 / 关键片段

```
# orchestrator 执行：
tmux send-keys -t "$SESSION:worker-alice.0" "你的任务是：搜索所有 BLE 初始化相关代码，输出文件路径和行号..." Enter

# worker 端显示：
[pasted text]▋
# 光标停在这里，不执行
```

## 根因分析

终端开启了 bracketed paste mode（现代 shell 默认开启）。在此模式下，tmux 将 `send-keys` 的字符串内容用 `\e[200~...\e[201~` 括起来整体发送，其中附带的 `Enter` 也被包进 bracket 内，shell 将整段视为"待确认的粘贴内容"而非命令，需要一次额外的 Enter（在 bracket 外）才会执行。

短文本不触发此问题，长文本（尤其是含换行、特殊字符或超过一定长度）才会命中。

## 修复方案

所有 `send-keys "任务文本" Enter` 之后，补发一条单独的 `send-keys "" Enter`，确保在 bracketed paste 结束后有一个裸 Enter 触发执行：

```bash
tmux send-keys -t "$SESSION:$WORKER_NAME.0" "你的任务是：..." Enter
sleep 0.3
tmux send-keys -t "$SESSION:$WORKER_NAME.0" "" Enter
```

已在 orchestrator.md 和 skill.md 的所有相关代码块中统一加入此补发步骤。

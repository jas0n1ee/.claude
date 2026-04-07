---
name: swarm
description: Orchestrator 管理 worker 的 tmux 操作命令库
---

# Swarm Skill：tmux 操作命令库

本文档供 orchestrator 在需要操作 worker 时参考。

---

## 创建 worker
```bash
SESSION=$(tmux display-message -p '#S')
WORKER_NAME="worker-alice"

tmux new-window -t "$SESSION" -n "$WORKER_NAME"
sleep 1
tmux send-keys -t "$SESSION:$WORKER_NAME.0" "dangerclaude" Enter
sleep 3  # 等待 claude 启动并完成身份检测
tmux send-keys -t "$SESSION:$WORKER_NAME.0" "/research_codebase 具体任务描述" Enter
sleep 0.3
tmux send-keys -t "$SESSION:$WORKER_NAME.0" "" Enter  # 防止 bracketed paste 模式吞掉 Enter
```

命名建议：`worker-alice`、`worker-bob` 等，使用简单易识别的名字，不需要包含角色。

---

## 给已有 worker 发送任务
```bash
SESSION=$(tmux display-message -p '#S')
tmux send-keys -t "$SESSION:worker-alice.0" "/implement_plan 具体任务描述" Enter
sleep 0.3
tmux send-keys -t "$SESSION:worker-alice.0" "" Enter  # 防止 bracketed paste 模式吞掉 Enter
```

---

## 复用 worker（清空上下文后分配新任务）
```bash
SESSION=$(tmux display-message -p '#S')
tmux send-keys -t "$SESSION:worker-alice.0" "/clear" Enter
sleep 1
tmux send-keys -t "$SESSION:worker-alice.0" "/implement_plan 新任务描述" Enter
sleep 0.3
tmux send-keys -t "$SESSION:worker-alice.0" "" Enter  # 防止 bracketed paste 模式吞掉 Enter
```

---

## 回收 worker
```bash
SESSION=$(tmux display-message -p '#S')
tmux kill-window -t "$SESSION:worker-alice"
```

任务全部完成、不再需要该 worker 时执行。

---

## 查看当前所有 worker 状态
```bash
SESSION=$(tmux display-message -p '#S')
tmux list-windows -t "$SESSION"
```

---

## 完整示例：从创建到回收
```bash
SESSION=$(tmux display-message -p '#S')

# 1. 创建两个 worker
tmux new-window -t "$SESSION" -n "worker-alice"
tmux new-window -t "$SESSION" -n "worker-bob"

# 2. 启动 claude 并等待就绪
sleep 1
tmux send-keys -t "$SESSION:worker-alice.0" "dangerclaude" Enter
tmux send-keys -t "$SESSION:worker-bob.0" "dangerclaude" Enter
sleep 3

# 3. 分配任务（补发 Enter 防止 bracketed paste 吞掉执行）
tmux send-keys -t "$SESSION:worker-alice.0" "/research_codebase 搞清楚 BLE 初始化入口在哪里" Enter
sleep 0.3
tmux send-keys -t "$SESSION:worker-alice.0" "" Enter
tmux send-keys -t "$SESSION:worker-bob.0" "/research_codebase_nt 确认 macOS 端 CoreBluetooth 依赖情况" Enter
sleep 0.3
tmux send-keys -t "$SESSION:worker-bob.0" "" Enter

# 4. 等待 TASK_DONE 汇报回来后，分配下一阶段任务
tmux send-keys -t "$SESSION:worker-alice.0" "/implement_plan 实现 ESP32 BLE 广播模块，入口在 ble_manager.c:42" Enter
sleep 0.3
tmux send-keys -t "$SESSION:worker-alice.0" "" Enter

# 5. 任务完成后回收
tmux kill-window -t "$SESSION:worker-alice"
tmux kill-window -t "$SESSION:worker-bob"
```

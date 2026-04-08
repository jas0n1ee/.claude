---
name: swarm
description: Orchestrator 管理 worker 的 tmux 操作命令库
---

# Swarm Skill：tmux 操作命令库

本文档供 orchestrator 在需要操作 worker 时参考。

---

## 身份优先级规则

### 用户明确指令 > 自动检测

当用户**直接告知**你是什么角色时（如"你是 self-improving agent"），立即执行该角色的激活流程，忽略 tmux 窗口名的自动检测结果。

**场景对比：**
| 场景 | 行为 |
|------|------|
| 启动时无用户指令 | 执行自动检测（读取 CLAUDE.md Swarm 模式逻辑） |
| 运行中用户明确指定角色 | 立即切换角色，覆盖当前身份 |

### 身份切换命令

```bash
# 激活 self-improving agent
SESSION=$(tmux display-message -p '#S')
CURRENT_WINDOW=$(tmux display-message -p '#W')
tmux rename-window -t "$SESSION:$CURRENT_WINDOW" "claude-self-improving"
```

---

## 稳定获取当前 Pane/Window/Session

**问题**：`TMUX_PANE` 是 shell 环境变量（非 tmux 变量），hook 执行时可能无法继承。

**解决方案**：使用 `tmux display-message` 直接获取 pane ID，再推导 window/session。

```bash
# 获取当前 pane ID（格式如 %7，唯一标识）
CURRENT_PANE=$(tmux display-message -p '#D')

# 通过 pane ID 获取 window 和 session（稳定，不随用户切换而变化）
CURRENT_WINDOW=$(tmux display-message -t "$CURRENT_PANE" -p '#W')
CURRENT_SESSION=$(tmux display-message -t "$CURRENT_PANE" -p '#S')
```

**关键区别**：
- `#P` - pane 在 window 内的索引（0, 1, 2...）
- `#D` - pane 的唯一 ID（%7, %8...），跨 session 唯一

**注意**：`tmux display-message -t {pane} -p '#W'` 的 `-t` 必须在 `-p` 之前。

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

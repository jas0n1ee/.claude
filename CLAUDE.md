# 使用 Python 时
- 通过 venv  来管理环境
- 当时区为 GMT+8 时，使用清华源加速https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple

# 文件操作安全守则

## 删除前必须做
1. **先查看目录内容** - 永远先用 `ls -la` 检查要删除的目录
2. **确认无重要文件** - 特别是 plans/, notes/, docs/ 等可能包含工作成果的目录
3. **不要假设结构** - 用户说"移动 X 到 Y"，要确认原位置是否有嵌套目录

## 移动/重命名规则
- 使用 `mv` 前，先确认源路径和目标路径
- 如果涉及嵌套目录（如 dev/thoughts/），逐层处理，不要批量删除

## 危险命令警示
- ❌ `rm -rf` - 删除前必须二次确认
- ❌ 不要组合使用 `mv` + `rm -rf` 而不检查中间状态

# Bug的呈递

For every bug:
1. Classify it first
2. State the primary environment for debugging:
3. Provide the smallest reproducible path.
4. Propose at most 2 candidate fixes, ranked by likelihood.
5. Do not introduce new infrastructure unless it directly helps this bug.
6. Report progress in user-visible terms, not framework phases.

## Swarm 模式

### Guard：检测是否在 tmux 中

启动时首先用 bash tool 执行：
```bash
[ -z "$TMUX" ] && echo "NOT_IN_TMUX" || echo "IN_TMUX"
```

如果输出是 `NOT_IN_TMUX`，跳过以下所有 swarm 逻辑，正常工作。

---

### 身份检测与升格

如果在 tmux 中，执行：
```bash
SESSION=$(tmux display-message -p '#S')
CURRENT_WINDOW=$(tmux display-message -p '#W')
HAS_ORCHESTRATOR=$(tmux list-windows -t "$SESSION" -F '#W' | grep -cE '^orchestrator(-|$)')

echo "SESSION=$SESSION"
echo "CURRENT_WINDOW=$CURRENT_WINDOW"
echo "HAS_ORCHESTRATOR=$HAS_ORCHESTRATOR"
```

根据输出判断：

- 如果 `HAS_ORCHESTRATOR=0`：当前 session 还没有 orchestrator，你来担任。执行：
```bash
  tmux rename-window -t "$SESSION:$CURRENT_WINDOW" orchestrator
```
  然后用 Read tool 读取 `swarm/orchestrator.md`，进入 orchestrator 模式。

- 如果 `HAS_ORCHESTRATOR=1` 且 `CURRENT_WINDOW=orchestrator`：你已经是 orchestrator，直接读取 `swarm/orchestrator.md`。

- 如果 `HAS_ORCHESTRATOR=1` 且 `CURRENT_WINDOW≠orchestrator`：你是 worker，读取 `swarm/worker.md`，进入 worker 模式。你的 identity 就是当前的 window 名。

# Ideas

新功能的想法池。想法先写在这里,成熟后再实现。

## 约定

- 一个想法一个文件:`NNN-short-slug.md`(三位序号 + 短横线小写短语),序号递增
- 文件开头用状态标记,方便追踪:

  | 状态 | 含义 |
  |------|------|
  | `draft` | 刚冒出来的想法,细节没想清 |
  | `design` | 方案基本成型,待评审/排期 |
  | `accepted` | 已确认要做,等实现 |
  | `rejected` | 放弃了(注明原因) |
  | `partial` | 部分落地:清单里勾掉已完成项,只留未做部分 |

- **完全实现后删除文件,README 里也不再列出** —— 想法池只放还没做的事。
  实现的留档看 git 历史、代码与 `docs/`,不在 `ideas/` 占位
- 部分实现的保留,状态标 `partial`,避免把未做的部分一起删掉

## 想法文件写什么

- **动机**:解决什么问题,什么场景
- **方案**:核心机制、关键代码骨架(想法阶段就写伪码/骨架,逼自己想清楚)
- **设计决策**:为什么这样做,拒绝了哪些替代方案
- **风险/未决问题**:安全、性能、语义分歧点
- **测试要点**:落地时要覆盖的行为

## 当前想法

| 编号 | 想法 | 状态 |
|------|------|------|
| [001](./001-project-scoped-tools.md) | 项目级工具目录(按会话 cwd 发现) | design |
| [002](./002-mcp2-stateless-client.md) | MCP 2.0 无状态客户端适配(2026-07-28 规范) | design |
| [003](./003-finish-reason-handling.md) | finish_reason 处理统一与兜底 | partial — 第 1 层兜底已落地 |
| [lark-acl-bindings](./lark-acl-bindings.md) | Lark ACL / 多路绑定 / P2P 私聊 | partial — P1–P3 已落地 |

> `lark-acl-bindings.md` 早于编号约定,保留原名(代码注释按此路径引用)。

## 已完成(已删除)

- 004 多 token 支持 → `lua/chat/tokens.lua`、各 `lua/chat/providers/*.lua`
  (key 冷却与切换)、`test/tokens_spec.lua`
- 005 get_history 结果语义 → `lua/chat/tools/get_history.lua`、
  `docs/tools/get_history.md`、`test/get_history_spec.lua`
- 006 记忆系统缺口修正 → `lua/chat/memory/*`、`lua/chat/tools/extract_memory.lua`、
  `lua/chat/tools/recall_memory.lua`、`test/memory_fixes_spec.lua`


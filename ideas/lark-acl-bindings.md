# Lark 集成增强方案书

- **状态**: 待评审 / 待实施
- **日期**: 2026-11-06
- **影响模块**: `lua/chat/integrations/lark.lua`, `lua/chat/integrations/init.lua`
- **兼容性原则**: 只增不改,旧集成 0 行改动,现有测试原样通过

---

## 1. 背景与现状

当前 `lark.lua` 的能力边界:

```lua
-- 现状
- 轮询单个 chat_id(配置文件写死)的群消息
- 只响应 @机器人 的消息(is_mention_bot)
- 没有任何用户权限校验,群里谁 @ 都会触发
- 回复固定发回配置的那个群
- session 绑定是平台级单值: integration.set_session(session)
```

### 1.1 三个核心痛点

| # | 痛点 | 影响 |
|---|------|------|
| P1 | **无权限控制** | 任何人在群里 @ 机器人即可对话,共享同一个会话上下文 |
| P2 | **单群绑定** | 多个群共享一个 session,上下文互相污染 |
| P3 | **不支持私聊** | 无法 P2P 单独对话,轮询架构下不知道用户的 p2p chat_id |

### 1.2 共享层契约(改动红线)

其他 7 个集成(discord/slack/telegram/wecom/dingtalk/weixin...)实现同一套接口契约,这些是**不能破坏**的:

| 契约 | 共享层依赖位置 | 改动威胁 |
|------|---------------|---------|
| `callback({content, author})` | `handle_message` 包装器 | 加 `chat_id` 字段是加法,安全 |
| `current_session()` 单值 | `on_response`、`unbridge`、`get_integrations`、HTTP routes | 改语义会全炸 |
| `send_message(content)` 单参数 | `M.on_response` 回复路由 | 改签名会全炸 |
| `set_session(sid)` | `/session` 命令、picker、HTTP API | 改语义会全炸 |

测试锁着这些契约:

```
test/integrations_init_spec.lua       -- 接口完整性
test/integrations_init_extra_spec.lua  -- set_session/unbridge 语义
test/http_spec.lua                     -- HTTP API 的 session 路由
test/integration_spec.lua              -- 多平台绑定关系
test/lark_integration_spec.lua         -- lark 自身(含 state roundtrip)
```

---

## 2. 总体设计

核心原则: **旧集成的代码一行都不动**,所有新能力通过 **"可选字段 + 可选方法 + nil 回退"** 实现。

```
+--------------------------------------------------------------+
|                       Phase 1: ACL                           |
|      谁可以和机器人对话 (allow_all / whitelist / blacklist)   |
+--------------------------------------------------------------+
|                    Phase 2: bindings 路由表                   |
|        一群绑一 session,消息按 chat_id 路由,回复定向           |
+--------------------------------------------------------------+
|                     Phase 3: P2P 私聊                         |
|         私聊发现 + 绑定,无需 @,天然隔离                        |
+--------------------------------------------------------------+
|                 Phase 4 (可选): WebSocket 长连接               |
|         事件订阅 im.message.receive_v1,秒级响应                |
+--------------------------------------------------------------+
```

---

## 3. Phase 1: 权限层 (ACL)

### 3.1 目标

控制"群里谁能和机器人对话"。open_id (`ou_xxx`) 无法伪造,比昵称可靠。

### 3.2 配置设计

```lua
integrations = {
  lark = {
    app_id = 'cli_xxx',
    app_secret = 'xxx',
    chat_id = 'oc_xxx',
    acl = {
      mode = 'whitelist',          -- allow_all | whitelist | blacklist
      whitelist = { 'ou_xxx' },    -- open_id
      blacklist = {},
      admins = { 'ou_admin' },     -- 可在群里执行管理命令的人
    },
  },
},
```

### 3.3 实现要点

```lua
local function get_acl()
  return config.config.integrations.lark.acl or {}
end

local function is_allowed(sender_id)
  local acl = get_acl()
  local mode = acl.mode or 'allow_all'

  if mode == 'whitelist' then
    return vim.tbl_contains(acl.whitelist or {}, sender_id)
  elseif mode == 'blacklist' then
    return not vim.tbl_contains(acl.blacklist or {}, sender_id)
  end
  return true -- allow_all, 保持向后兼容
end
```

### 3.4 管理入口

- **Neovim 侧**: 轮询时顺手缓存最近发言者的 open_id 到 state 文件,做一个 picker 列出"最近发言人",action 是 allow / deny / 绑定 session。不用去翻 open platform 后台抄 ID
- **群里侧 (Phase 2+)**: 拦截 `@机器人 /allow @张三` 这类命令,校验 sender 是 admin 后更新持久化的 ACL 文件。拒绝时**静默丢弃**比回一句"无权限"好,避免刷屏

另外飞书管理后台本身有 **应用可用范围**(谁能看到/使用这个机器人),这是最外层粗粒度控制,代码里的 ACL 管细粒度。

### 3.5 影响面

只动 `lark.lua` + 新增 picker,共享层 **0 行改动**。

---

## 4. Phase 2: 多路绑定 (bindings)

### 4.1 目标

一个群绑一个 session,消息按 `chat_id` 路由,回复定向到来源群。

### 4.2 数据结构

```lua
-- state 里持久化
bindings = {
  { chat_id = 'oc_group_a',  chat_type = 'group', session = 'sess-1' },
  { chat_id = 'oc_group_b',  chat_type = 'group', session = 'sess-2' },
  { chat_id = 'oc_p2p_xxx',  chat_type = 'p2p',   session = 'sess-3', peer = 'ou_user' },
}
```

### 4.3 回调携带来源

```lua
-- fetch_messages 里
state.callback({
  author = msg.sender.id,
  chat_id = msg.chat_id,     -- 新增,其他集成根本不设置这个字段
  message_id = msg.message_id,
  content = content,
})
```

### 4.4 共享层改造(只增不改)

**a. handle_message 按目标解析 session — nil 回退:**

```lua
-- integrations/init.lua,改动约 4 行
local session = integration.current_session()
-- Backward-compatible: per-chat routing only when integration supports it
if message.chat_id and integration.get_binding then
  session = integration.get_binding(message.chat_id) or session
end
```

旧集成没有 `get_binding` 方法 → 条件短路 → 行为和现在逐字节一致。

**b. on_response 路由 — 利用 Lua 宽松参数:**

```lua
if matched then
  integration.send_message(content, session)  -- 第二参数是可选的
end
```

- 旧集成: `function M.send_message(content)` 收到多余的 `session` 参数直接丢弃 → 发到自己唯一的频道 → 正确
- lark: 用 `session` 反查 bindings 表找到目标 chat_id → 定向回复 → 正确

**c. current_session / set_session 保持原语义:**

```lua
-- lark.lua 内部
M.current_session()      -- 仍返回主绑定的 session,unbridge/picker/HTTP 全部正常
M.get_bound_sessions()  -- 新增可选方法,返回所有绑定的 session 列表
```

`on_response` 里加 nil 守卫的匹配扩展:

```lua
local matched = session == integration.current_session()
if not matched and integration.get_bound_sessions then
  matched = vim.tbl_contains(integration.get_bound_sessions(), session)
end
```

**d. `/session` 命令 — 新方法存在才走新路径:**

```lua
-- handle_session_command 里
if integration.set_binding and message.chat_id then
  integration.set_binding(message.chat_id, sid)  -- 群 A 绑 sess-1 不影响群 B
else
  integration.set_session(sid)  -- 旧路径
end
```

### 4.5 回复定向

群里体验更好(回复挂在触发消息下):

```
POST /im/v1/messages/{message_id}/reply
```

### 4.6 影响面

`lark.lua` + `init.lua` 约 15 行 nil 守卫,旧集成 **0 行改动**,全部向后兼容。

---

## 5. Phase 3: P2P 私聊

### 5.1 目标

用户直接和机器人单聊,私聊上下文天然与群隔离,无需 @。

### 5.2 难点

飞书的坑: **收私聊消息的标准姿势是事件订阅**,纯轮询模式下机器人不知道用户的 p2p chat_id(`GET /im/v1/chats` 是否包含 p2p 会话需要验证,官方文档倾向只返回群)。

### 5.3 轮询架构下的发现法

```
1. 用户先在任意群里 @机器人 一次 → 拿到他的 open_id(顺手缓存)
2. Neovim 里 picker 选中某人 → "绑定私聊"
3. 发送接口 receive_id_type=open_id 主动私发一条 hello → 拿到 message_id
4. GET /im/v1/messages/{message_id} 消息详情 → 拿到 p2p chat_id(oc_xxx,长期稳定)
5. 持久化 binding,之后像轮询群一样轮询这个 p2p 容器
```

### 5.4 实现要点

拿到 chat_id 后,现有 `fetch_messages` 逻辑几乎不用改,只加一条: **p2p 消息不需要 @**(私聊里没人会 @ 机器人)。判断方式不依赖 API 返回 `chat_type` 字段 — binding 表里自己记了 `chat_type`,查表即可。

### 5.5 影响面

只动 `lark.lua`(建立在 Phase 2 之上),共享层 **0 行改动**。

---

## 6. Phase 4 (可选): WebSocket 长连接事件订阅

飞书支持 **长连接模式** 事件订阅(专为无公网 IP 的本地应用设计,`im.message.receive_v1`),不需要把 Neovim 的 HTTP server 暴露公网。

- **优点**: 秒级响应、p2p 天然支持,体验最好
- **缺点**: 需要实现一个 WebSocket 客户端(curl 干不了这事),工程量不小

留作 Phase 4,前三阶段轮询就够用。新模块独立实现,共享层和旧集成 **0 行改动**。

---

## 7. 风险分析

### 7.1 风险总表

| Phase | 改动文件 | 旧集成改动 | 共享层改动 | 风险等级 |
|-------|---------|-----------|-----------|---------|
| 1 ACL | lark.lua + 新 picker | **0 行** | **0 行** | 低 |
| 2 bindings | lark.lua + init.lua ~15 行 nil 守卫 | **0 行** | 全部向后兼容 | 中 |
| 3 P2P | 只动 lark.lua | **0 行** | **0 行** | 低(依赖 Phase 2) |
| 4 WebSocket | 新模块 | **0 行** | **0 行** | 高(工程量大) |

### 7.2 最坏情况

按"可选方法 + nil 回退"的方式改,旧集成一行不用动、所有现有测试应该原样通过;最坏的情况只是**新路径没生效、回退到现在的单群绑定行为**,不会造成破坏。

### 7.3 state 兼容

`lark_integration_spec.lua` 里有 reload 模块的测试(`package.loaded[...] = nil`),改完 state 结构后必须确认 state roundtrip 仍然通过 — `load_state()` 里用 nil 守卫读新字段,旧 state 文件加载不受影响。

---

## 8. 分阶段落地

| Phase | 内容 | 改动量 | 建议优先级 |
|-------|------|--------|-----------|
| 1 | ACL 校验 + 最近发言人缓存 + Neovim picker 管理 | 小,只动 lark.lua + 新 picker | ⭐⭐⭐ 立刻解决 P1 痛点,无 breaking change |
| 2 | bindings 路由表 + 回复定向 + 共享层消息流 nil 守卫 | 中 | ⭐⭐ 解决 P2,为 Phase 3 打基础 |
| 3 | P2P 发现 + 绑定私聊 | 小(建立在 Phase 2 上) | ⭐⭐ 解决 P3 |
| 4 | WebSocket 长连接事件订阅 | 大 | ⭐ 可选,体验最优 |

**建议**: Phase 1 + 2 一起做,跑完 `make test` 确认契约测试全绿后再进入 Phase 3。

---

## 9. 待办清单

- [ ] Phase 1: `is_allowed()` + ACL 配置 + 最近发言人缓存
- [ ] Phase 1: ACL picker(allow / deny / bind session)
- [ ] Phase 2: bindings 数据结构 + state 持久化 + roundtrip 测试
- [ ] Phase 2: `get_binding` / `set_binding` / `get_bound_sessions` 可选方法
- [ ] Phase 2: 共享层 4 处 nil 守卫(handle_message / on_response / send_message / /session)
- [ ] Phase 2: reply 定向回复接口
- [ ] Phase 3: P2P 发现流程(picker → 私发 hello → 拿 chat_id → 持久化)
- [ ] Phase 3: p2p 免 @ 判定(查 binding 表 chat_type)
- [ ] Phase 4: WebSocket 客户端(独立模块,可选)
- [ ] 每个 Phase 完成后跑 `make test`,确认 5 个契约 spec 全绿


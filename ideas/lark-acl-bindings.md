# Lark 集成增强方案书

- **状态**: 待评审 / 待实施
- **日期**: 2026-11-07
- **影响模块**: `lua/chat/integrations/lark.lua`, `lua/chat/integrations/init.lua`, `lua/chat/integrations/lark/identity.lua`(新增)
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

### 1.3 Neovim 侧命令现状

`:Chat bridge` 是平台级命令(见 4.5):

```lua
-- plugin/chat.lua(现状)
elseif #opt.fargs > 0 and opt.fargs[1] == 'bridge' then
  require('chat.integrations').set_session(
    opt.fargs[2],                              -- 只取平台名
    require('chat.windows').current_session()  -- 绑定当前窗口 session
  )
  require('chat.windows').redraw_title()
```

- 命令参数只有平台名维度,**没有 chat_id 维度**
- `:Chat bridge lark` 的语义就是"lark 平台 → 当前 session"
- chat_id 是 `oc_xxx` 的 30+ 位长串,命令行手输不现实,也不该往这个方向扩展

> 现状小瑕疵(不在本方案范围): bridge 的补全函数会持续返回平台名列表,但处理函数只取
> `fargs[2]` — `:Chat bridge lark discord` 实际只绑 lark;而 `unbridge` 支持多平台列表。

---

## 2. 总体设计

核心原则: **旧集成的代码一行都不动**,所有新能力通过 **"可选字段 + 可选方法 + nil 回退"** 实现。

```
+--------------------------------------------------------------+
|                       Phase 1: ACL                           |
|      谁可以和机器人对话 (allow_all / whitelist / blacklist)   |
|      身份入口: open_id / 邮箱 / 手机号 (归一化到 open_id)      |
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

配套目标: **管理员配置不被迫去后台抄 30+ 位的 `ou_xxx`**。借助应用已申请的
`contact:user.employee_id:readonly` 权限,允许用邮箱 / 手机号书写,connect 时统一
解析为 open_id 后再参与比对。

### 3.2 身份标识与归一化

#### 3.2.1 为什么必须归一化

飞书存在**两套互不相等的用户 ID 体系**:

| 来源 | 形态 | 能否与消息 `sender.id` 直接比对 |
|------|------|-------------------------------|
| 消息回调 `msg.sender.id` | `ou_xxx`(open_id) | ✅ 这是唯一可靠口径 |
| 开放平台后台「成员详情」可复制 | `us_xxx`(企业 user_id) | ❌ 与 open_id 永远不相等 |

所以 ACL 里的任何字符串,最终都必须落到 **open_id 空间**再比对。邮箱和手机号只是
**书写便利**,不是比对依据。

`POST /contact/v3/users/batch_get_id` 还有一个隐形陷阱: **必须显式传
`user_id_type=open_id`**,否则响应里 `user_list[].user_id` 返回的是 user_id 体系的值,
看起来"换到了 ID",实际匹配不上。

#### 3.2.2 支持的三种输入

| 输入形态 | 示例 | 处理 | 是否消耗 API 请求 |
|---------|------|------|------------------|
| open_id | `ou_95904d939749487b272aaa73a91bb916` | 原样使用 | 否 |
| 邮箱 | `nova@example.com` | `batch_get_id` 解析 | 是 |
| 手机号 | `+8613800138000` | `batch_get_id` 解析 | 是 |
| 企业 user_id | `us_xxxxx` | **不支持,connect 时报错** | — |

`us_xxx` 转 open_id 需要 `contact:user.base:readonly`(或更宽的通讯录读权限),为了一个
"抄错 ID"的容错去多申请一个权限不划算。文档、日志、错误信息里一律引导: **要么用
open_id,要么用邮箱/手机号**。

#### 3.2.3 解析流程

```
connect()
  └─ 收集 acl.whitelist ∪ acl.blacklist ∪ acl.admins 的全部条目
       ├─ 已是 ou_xxx  → 直接进 result 表
       ├─ 是邮箱       → 进 emails 池
       ├─ 是手机号     → 进 mobiles 池
       └─ 是 us_xxx 或无法识别 → log.error,记入 failed
  └─ 若 emails/mobiles 非空 → POST batch_get_id(user_id_type=open_id)
       Body: { "emails": [...], "mobiles": [...] }   (单次上限 50,超出分批)
       Resp: data.user_list[] → 按返回的 email/mobile 字段回填 result
       查不到的条目同样记入 failed
  └─ result 写入 state.identities(持久化),后续轮询零请求
```

归一化后,运行期 ACL 比对只做**纯字符串集合判断**,不产生任何网络开销。

#### 3.2.4 实现骨架(新模块 `lua/chat/integrations/lark/identity.lua`)

```lua
local M = {}

local API_BASE = 'https://open.feishu.cn/open-apis'
local BATCH_SIZE = 50

-- Classify a single configured entry by its shape.
local function classify(entry)
  if entry:match('^ou_') then
    return 'open_id'
  elseif entry:find('@') then
    return 'email'
  elseif entry:match('^%+?%d') then
    return 'phone'
  elseif entry:match('^us_') then
    return 'user_id' -- unsupported on purpose, see 3.2.2
  end
  return 'unknown'
end

-- Resolve a list of mixed entries into open_id space.
-- callback({ [text] = open_id, failed = { text, ... } })
function M.resolve(entries, callback)
  local out, emails, mobiles, failed = {}, {}, {}, {}

  for _, entry in ipairs(entries) do
    local kind = classify(entry)
    if kind == 'open_id' then
      out[entry] = entry
    elseif kind == 'email' then
      table.insert(emails, entry)
    elseif kind == 'phone' then
      table.insert(mobiles, entry)
    else
      -- Unsupported entries are reported, never dropped silently
      log.error('[Lark] Unsupported identity entry: ' .. entry)
      table.insert(failed, entry)
    end
  end

  -- open_id only: no lookup needed, zero API requests
  if #emails == 0 and #mobiles == 0 then
    out.failed = failed
    return callback(out)
  end

  -- NOTE: user_id_type=open_id is mandatory, see 3.2.1
  local endpoint = API_BASE
    .. '/contact/v3/users/batch_get_id?user_id_type=open_id'

  -- POST body: { emails = {...}, mobiles = {...} }, chunked by BATCH_SIZE
  -- Response: data.user_list[] each carrying `user_id` (an open_id here),
  -- plus the matched `email` / `mobile` used as the reverse map key.
  -- Entries the API cannot match are appended to `failed` as well.
  -- ...
  out.failed = failed
  callback(out)
end

return M
```

#### 3.2.5 权限与限制(实施时必须核对)

| 项 | 说明 |
|----|------|
| 依赖权限 | `contact:user.employee_id:readonly`(已申请)。缺权限时接口返回无权限错误码 |
| 单次上限 | 50 个邮箱 / 手机号,超出需分批 |
| 匹配前提 | 目标用户必须与机器人在同一 tenant,且在应用**可用范围**内 |
| 手机号格式 | 建议带国际区号(`+8613800138000`);返回值的格式可能与输入不同,回填时按**归一化后**的形式做 key |
| 查不到的用户 | 该条目解析失败 → 记入 `failed`,并在日志里点名,绝不静默 |

#### 3.2.6 缓存与失效

`state.identities` 持久化到 `lark.json`(与 `session`、`bindings` 同级),结构:

```lua
identities = {
  ['nova@example.com'] = 'ou_95904d939749487b272aaa73a91bb916',
  ['+8613800138000']   = 'ou_543e6f73f6eba025fa7fc536d39204bb',
}
```

同时保存 `identities_config_hash`(所有 ACL 条目排序后拼接的校验和):

- hash 不变 → 直接用缓存,零请求
- hash 变化(用户改了配置) → 重新解析,失败时保留旧缓存(旧值仍可能有效)

`load_state()` 里对这两个新字段做 nil 守卫,**旧 state 文件照常加载**(见 7.3)。

#### 3.2.7 解析失败的降级策略

| 场景 | 行为 |
|------|------|
| 某条目解析失败(查无此人 / 权限不足) | 该条目失效,日志点名;其余条目正常工作 |
| `admins` 里有条目解析失败 | **fail closed**: 该配置视为不存在,绝不放宽权限 |
| `whitelist` 里有条目解析失败 | **fail closed**: 不加入白名单 |
| `blacklist` 里有条目解析失败 | 无法识别该人 → 实际放行,日志 warn 提示尽快修正 |
| 整个接口不可用(网络 / 权限) | 只保留 `ou_xxx` 条目可用,其余失效并 warn |

### 3.3 配置设计

```lua
integrations = {
  lark = {
    app_id = 'cli_xxx',
    app_secret = 'xxx',
    chat_id = 'oc_xxx',
    acl = {
      mode = 'whitelist',          -- allow_all | whitelist | blacklist
      whitelist = {
        'ou_95904d939749487b272aaa73a91bb916', -- open_id: 零请求,推荐
        'nova@example.com',                    -- 邮箱
        '+8613800138000',                      -- 手机号(建议带国际区号)
      },
      blacklist = {},
      admins = {
        'admin@example.com',                   -- 可用邮箱/手机号书写
      },
    },
  },
},
```

配置书写约定:

- 三种格式可**混写**在同一张表里,逐个按形态判定(见 3.2.3)
- `ou_xxx` 优先: 不消耗接口、不受可用范围/权限变化影响
- 邮箱、手机号在 connect 时一次性解析,运行期无额外请求
- `us_xxx` 禁止使用,connect 时明确报错

### 3.4 实现要点

```lua
local identity = require('chat.integrations.lark.identity')

local function get_acl()
  return config.config.integrations.lark.acl or {}
end

-- text -> open_id, filled once at connect (see 3.2.3)
local resolved = {}

-- Normalize one configured entry into open_id space.
-- Returns nil when the entry is not usable (fail closed for admins/whitelist).
local function to_open_id(entry)
  if resolved[entry] then
    return resolved[entry]
  end
  if entry:match('^ou_') then
    return entry -- already an open_id, usable even without resolution
  end
  return nil -- email / phone unresolved, or unsupported user_id
end

-- Resolve ACL entries to open_id space at connect time.
local function resolve_acl(callback)
  local acl = get_acl()
  local entries = {}
  vim.list_extend(entries, acl.whitelist or {})
  vim.list_extend(entries, acl.blacklist or {})
  vim.list_extend(entries, acl.admins or {})

  identity.resolve(entries, function(result)
    resolved = result
    callback()
  end)
end

local function is_allowed(sender_id)
  local acl = get_acl()
  local mode = acl.mode or 'allow_all'

  -- Always compare in open_id space: config may hold email / phone
  if mode == 'whitelist' then
    for _, entry in ipairs(acl.whitelist or {}) do
      if to_open_id(entry) == sender_id then
        return true
      end
    end
    return false
  elseif mode == 'blacklist' then
    for _, entry in ipairs(acl.blacklist or {}) do
      if to_open_id(entry) == sender_id then
        return false
      end
    end
    return true
  end
  return true -- allow_all, 保持向后兼容
end

local function is_admin(sender_id)
  for _, entry in ipairs(get_acl().admins or {}) do
    if to_open_id(entry) == sender_id then
      return true
    end
  end
  return false
end
```

三个判定函数一律通过 `to_open_id()` 归一化后再比对:

- `admins` / `whitelist` 未解析成功的条目返回 nil → 永不匹配 → **fail closed**
- `blacklist` 未解析成功的条目返回 nil → 永不匹配 → **fail open**(放行 + warn),与 3.2.7 一致

### 3.5 管理入口

- **Neovim 侧**: 轮询时顺手缓存最近发言者的 open_id 到 state 文件(顺带记录发信时的
  chat_id),做一个 picker 列出"最近发言人",action 是 allow / deny / 绑定 session。
  直接写入 open_id 形式的配置,**完全不需要通讯录接口,也不用手抄长 ID**
- **群里侧 (Phase 2+)**: 拦截 `@机器人 /allow @张三` 这类命令,校验 sender 是 admin
  后更新持久化的 ACL 文件。拒绝时**静默丢弃**比回一句"无权限"好,避免刷屏

优先推荐 picker 路径: 它产出的天然是 open_id,为邮箱/手机号解析这类"便利功能"
不需要成为主路径 —— 手工编辑 `config` 的场景才走 `identity.resolve`。

另外飞书管理后台本身有 **应用可用范围**(谁能看到/使用这个机器人),这是最外层粗粒度控制,代码里的 ACL 管细粒度。

### 3.6 影响面

只动 `lark.lua`,新增 `lua/chat/integrations/lark/identity.lua`(与 `chat.integrations.lark.auth` 同级),
新增 picker。共享层 **0 行改动**,其他 7 个集成 **0 行改动**。

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

**d. 群内 `/session` 命令 — 新方法存在才走新路径:**

```lua
-- handle_session_command 里
if integration.set_binding and message.chat_id then
  integration.set_binding(message.chat_id, sid)  -- 群 A 绑 sess-1 不影响群 B
else
  integration.set_session(sid)  -- 旧路径
end
```

### 4.5 绑定入口设计

`:Chat bridge` 命令是平台级的(fargs 只取平台名,绑定当前 session),命令行接口
**表达不了"绑哪个 chat"**。因此 per-chat 绑定不通过命令行参数扩展,而是用三条入口各司其职:

| 入口 | 谁在用 | 绑哪个 chat | 实现 |
|------|--------|-------------|------|
| `:Chat bridge lark` | Neovim 用户 | 主 chat_id(config 的 chat_id) | **语义不变**: `set_session()` 内部同步主 binding |
| 群内 `/session` | 群成员(过 ACL) | 消息来源 chat_id(天然携带) | `set_binding(message.chat_id, sid)` |
| Neovim picker | Neovim 用户 | 任意已缓存 chat | 列出 bindings + 缓存的最近聊天,选中绑到当前 session |

**平台级 `set_session` 被定义为主绑定操作**(lark.lua 内部):

```lua
function M.set_session(session)
  state.session = session                 -- current_session() 兼容,unbridge/HTTP/标题全不变
  if session then
    set_binding(main_chat_id(), session)  -- 主 binding 同步更新: config.chat_id → session
  end
  save_state()
end
```

旧调用方(`:Chat bridge` 命令、HTTP API、现有 picker)全部无感知,行为与现在一致 —
区别只是 lark 内部多维护了一张 bindings 表。

### 4.6 回复定向

群里体验更好(回复挂在触发消息下):

```
POST /im/v1/messages/{message_id}/reply
```

### 4.7 影响面

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

> 注: 步骤 3 用 `receive_id_type=open_id` 直接私发,**不需要**邮箱/手机号解析 ——
> ACL 归一化(3.2)产出的 open_id 在这里正好复用。

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
| 1 ACL | lark.lua + **lark/identity.lua** + 新 picker | **0 行** | **0 行** | 低 |
| 2 bindings | lark.lua + init.lua ~15 行 nil 守卫 | **0 行** | 全部向后兼容 | 中 |
| 3 P2P | 只动 lark.lua | **0 行** | **0 行** | 低(依赖 Phase 2) |
| 4 WebSocket | 新模块 | **0 行** | **0 行** | 高(工程量大) |

### 7.2 最坏情况

按"可选方法 + nil 回退"的方式改,旧集成一行不用动、所有现有测试应该原样通过;最坏的情况只是**新路径没生效、回退到现在的单群绑定行为**,不会造成破坏。

ACL 侧同理: 归一化失败时只剩 `ou_xxx` 条目有效,行为等价于"只用 open_id 配置",
即本方案 3.2 之前的状态。

### 7.3 state 兼容

`lark_integration_spec.lua` 里有 reload 模块的测试(`package.loaded[...] = nil`),改完 state 结构后必须确认 state roundtrip 仍然通过 — `load_state()` 里用 nil 守卫读新字段(`identities` / `identities_config_hash` / `bindings`),旧 state 文件加载不受影响。

---

## 8. 分阶段落地

| Phase | 内容 | 改动量 | 建议优先级 |
|-------|------|--------|-----------|
| 1 | ACL 校验 + 身份归一化(open_id/邮箱/手机号) + 最近发言人缓存 + Neovim picker 管理 | 小,只动 lark.lua + 新 identity.lua + 新 picker | ⭐⭐⭐ 立刻解决 P1 痛点,无 breaking change |
| 2 | bindings 路由表 + 回复定向 + 共享层消息流 nil 守卫 | 中 | ⭐⭐ 解决 P2,为 Phase 3 打基础 |
| 3 | P2P 发现 + 绑定私聊 | 小(建立在 Phase 2 上) | ⭐⭐ 解决 P3 |
| 4 | WebSocket 长连接事件订阅 | 大 | ⭐ 可选,体验最优 |

**建议**: Phase 1 + 2 一起做,跑完 `make test` 确认契约测试全绿后再进入 Phase 3。

---

## 9. 待办清单

- [ ] Phase 1: `is_allowed()` + `is_admin()` + ACL 配置 + 最近发言人缓存
- [ ] Phase 1: `lua/chat/integrations/lark/identity.lua` — 形态判定 + `batch_get_id`(`user_id_type=open_id`,50/批)
- [ ] Phase 1: `connect()` 时解析 whitelist/blacklist/admins,失败逐条点名(fail closed)
- [ ] Phase 1: `state.identities` + `identities_config_hash` 持久化与缓存失效,`load_state()` nil 守卫
- [ ] Phase 1: `us_xxx` 条目显式报错,日志引导改用 open_id / 邮箱 / 手机号
- [ ] Phase 1: 手机号归一化(国际区号)与回填 key 一致性
- [ ] Phase 1: ACL picker(allow / deny / bind session)
- [ ] Phase 2: bindings 数据结构 + state 持久化 + roundtrip 测试
- [ ] Phase 2: `get_binding` / `set_binding` / `get_bound_sessions` 可选方法
- [ ] Phase 2: 共享层 4 处 nil 守卫(handle_message / on_response / send_message / 群内 /session)
- [ ] Phase 2: `:Chat bridge lark` 主绑定语义保持(平台级 set_session 同步主 binding,旧调用方零感知)
- [ ] Phase 2: 绑定管理 picker(列出 bindings + 最近聊天 → 绑到当前 session)
- [ ] Phase 2: reply 定向回复接口
- [ ] Phase 3: P2P 发现流程(picker → 私发 hello → 拿 chat_id → 持久化)
- [ ] Phase 3: p2p 免 @ 判定(查 binding 表 chat_type)
- [ ] Phase 4: WebSocket 客户端(独立模块,可选)
- [ ] 每个 Phase 完成后跑 `make test`,确认 5 个契约 spec 全绿


# 004 - 多 token 支持（多账号 api_key 轮询/故障切换）

**状态:** draft

## 动机

同一个 provider 有多账号（多张卡 / 多组配额）是常见操作，尤其是**字节 Coding
plan**（`volcengine_coding_plan`）这类走火山方舟的通道：一个账号一个
`api_key`，配额单独计。现在的配置只允许一个 provider 挂**一个** key，一旦
单个 key 触发限流（429）或 5xx，就只能等冷却，聊天体验被单个账号的限流
拖住。

想要的能力：配置里把同一 provider 的多个 key 全写上，调用时**自动在多个
key 之间切换**（轮询 / 失败切换），单 key 限流不影响整体可用性。

## 现状

`config.api_key` 是 `string | ChatConfigApiKey`，而
`ChatConfigApiKey = table<string, string>` —— 每个 provider 映射到**单个字符
串** key：

```lua
-- lua/chat/config.lua
---@alias ChatConfigApiKey table<string, string>
---@field api_key? string | ChatConfigApiKey
```

provider 的 `request` 里直接取单值拼到 header：

```lua
-- lua/chat/providers/volcengine_coding_plan.lua
'Authorization: Bearer ' .. config.config.api_key.volcengine_coding_plan,
```

没有多 key 概念，限流/故障只能等 `http.lua` 的 retry（重试还是打同一个
key），没有任何 key 层面的切换。

## 方案

### 第 1 层：配置类型扩展（向后兼容）

让 `api_key[provider]` 支持 `string`（单 key，现状不动）或 `string[]`（多
key）。取 key 时统一到一个入口函数：

```lua
-- 新增 lua/chat/tokens.lua（名字待定，见"设计决策"）
local config = require('chat.config')

--- 因为 config 模块 require 出来是 M，运行时配置在 M.config，
--- 所以是 config.config.api_key。<provider>。
--- 返回 provider 的 key 列表（单 key 也归一成单元素数组）。
local function normalize(provider)
  local key = config.config.api_key[provider]
  if key == nil then
    return nil
  elseif type(key) == 'string' then
    return { key }
  else
    return vim.tbl_filter(function(v) return v ~= nil and v ~= '' end, key)
  end
end

--- 取第 index 个 key（1-based），支持回绕。
--- 单 key 永远返回同一个，多 key 按 index 轮转。
local function get_token(provider, index)
  local keys = normalize(provider)
  if not keys or #keys == 0 then
    return nil
  end
  return keys[((index - 1) % #keys) + 1]
end

return {
  normalize = normalize,
  get_token = get_token,
}
```

### 第 2 层：key 状态管理（轮询 + 故障冷却）

模块内维护每个 provider 的游标和冷却表，暴露 `next()` / `fail()`：

```lua
local M = {}

-- provider -> { index = number, cooldown = { [key_index] = cooldown_until } }
local state = {}

local function now() return vim.uv.now() / 1000 end  -- 秒

local function cooldown_seconds()
  return (config.config.http and config.config.http.token_cooldown) or 30
end

--- 返回下一个可用的 key 与其 index；全在冷却时返回 nil。
function M.next(provider)
  local keys = normalize(provider)
  if not keys or #keys == 0 then
    return nil, nil
  end

  local s = state[provider]
  if not s then
    s = { index = 1, cooldown = {} }
    state[provider] = s
  end

  -- 从当前游标起，找第一个不在冷却的 key
  for _ = 1, #keys do
    s.index = ((s.index - 1) % #keys) + 1
    local i = s.index
    local until_t = s.cooldown[i] or -math.huge
    if now() >= until_t then
      return keys[i], i
    end
    s.index = s.index + 1  -- 跳过冷却中的，看下一个
  end

  return nil, nil  -- 全部冷却
end

--- 标记 key 失败，进入冷却，游标推进到下一个。
function M.fail(provider, key_index)
  local s = state[provider]
  if not s then
    s = { index = 1, cooldown = {} }
    state[provider] = s
  end
  s.cooldown[key_index] = now() + cooldown_seconds()
  s.index = key_index + 1
end

--- 重置游标（会话切换 provider 等场景）。
function M.reset(provider)
  state[provider] = nil
end
```

### 第 3 层：provider 接入

`request` 里用 `tokens.next(provider)` 取 key，并把「本次用到的 key 索引」
随 jobid 关联起来，供 `on_exit` / 错误路径回调 `tokens.fail(provider, idx)`：

```lua
-- volcengine_coding_plan.lua（示意）
local tokens = require('chat.tokens')

local key, idx = tokens.next('volcengine_coding_plan')
if not key then
  -- 全部冷却：要么直接报错，要么退回第一个 key 硬试，策略见"未决问题"
  return nil, 'all tokens cooling down'
end

local cmd = curl.build_request({
  ...
  headers = {
    'Content-Type: application/json',
    'Authorization: Bearer ' .. key,
  },
})

-- on_exit 里根据退出码 / stderr 判断是否限流/5xx，
-- 是则 tokens.fail('volcengine_coding_plan', idx)
```

「是否失败」不应靠解析 finish_reason，而要看 HTTP 状态 / stderr 里的
429、5xx、`rate limit` 等信号（与 003 想解耦控制流的思路一致）。

## 设计决策

1. **`get_token(provider, index)` 只做「按索引取」这一件事。** 用户稿子里
   的核心函数保留，但真正的“该用第几个”由 `next()` 的游标 + 冷却状态决定，
   避免把调度逻辑塞进纯取 token 的函数里。

2. **向后兼容优先。** `api_key[provider]` 是字符串时归一成单元素数组，
   行为与现在完全一致，不要求用户改配置就能享受新路径。多 key 用户改写成
   数组即可。

3. **失败切换 + 轮询叠加，默认只轮询。** 无故障时依次轮询摊薄配额；
   命中限流/5xx 才把该 key 冷却，自动滑到下一个。避免「永远用第一个 key
   直到它爆」的退化行为。

4. **故障判断走 HTTP 层信号，不碰模型内容。** 429 / 5xx / `rate limit`
   文本才算失败；`max_tokens` 截断、`content_filter` 是**正常结束**，不能
   把 key 打入冷却（否则截断就换 key，语义错了）。

5. **状态不持久化。** 游标和冷却表是内存态，重启归零可接受；持久化当前
   index 收益小、复杂度高（见"未决问题"）。

## 风险 / 未决问题

- **全部 key 冷却时怎么办？** 选型：
  (a) 直接报错让用户看到；
  (b) 退回最近冷却的那个 key 硬试（可能又 429，但至少尝试）；
  (c) 阻塞等待冷却结束。倾向 (a) + 明确提示，避免静默失败或空转。

- **并发下单游标竞争。** Neovim 的 job 回调是单线程消息循环，`state` 表
  在单个 Lua state 里，普通并发不存在真正的数据竞争；但多个会话同时请求
  同一 provider 时，游标推进顺序不可控，语义上是「全局轮询」而非「会话
  隔离」。是否按 session 独立游标待定。

- **冷却时长可否配。** 先固定一个默认值（如 30s），后续并入
  `http.token_cooldown` 配置项。不同 provider 限流窗口差异大，硬编码可能
  对某 provider 太短（马上又 429）或太长（空等）。

- **与 `http.lua` retry 的职责边界。** retry 管「网络抖动重试」，token 切换
  管「配额/限流换号」。两者都可能在 429 上触发，需明确：retry 是否只在
  **同一 key 内**重试，跨 key 切换交给 tokens 模块，避免双重放大。

- **错误信号识别跨 provider 不统一。** 火山方舟、OpenAI、Anthropic、Gemini
  的限流/错误响应格式各异。需要抽一个 `is_retryable(status, stderr)` 之类
  的统一判断，否则每个 provider 各写一套。

- **`ChatConfigApiKey` 类型别名要改。** 从 `table<string, string>` 改成
  `table<string, string | string[]>`（或引入 `ChatApiKeyValue` 别名），
  LSP/文档同步更新。

## 测试要点

- `normalize`:单字符串 → 单元素数组；多 key 数组 → 原样（过滤空串 / nil）
- `get_token`:index 回绕（3 个 key 取 index=4 得第 1 个）；单 key 任何
  index 都返回同一个；无 key 返回 nil
- `next`:轮询顺序正确；某一 key 被 `fail` 后短时间内不再返回它；冷却到期
  后恢复可用；全冷却时返回 nil
- `fail` 后游标推进，下一次 `next` 跳过失败 key
- 配置兼容：只写 `string` 的旧配置跑起来行为不变（回归）
- 照规矩 `config.setup({ storage_dir = temp })` 起隔离环境，绝不动真实配置

## 落地范围

- `lua/chat/config.lua`:类型别名 `ChatConfigApiKey` 扩展 + 注释
- `lua/chat/tokens.lua`(新):`normalize` / `get_token` / `next` / `fail` /
  `reset`
- 各 `lua/chat/providers/*.lua`:`request` 里改 `tokens.next()` 取 key，
  `on_exit` 里按 HTTP 信号 `tokens.fail()`
- `http.lua` 的 retry 逻辑核对，明确与 token 切换的边界
- 文档：`docs/` 里 provider / config 相关说明同步

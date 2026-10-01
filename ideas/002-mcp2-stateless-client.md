# 002 - MCP 2.0 无状态客户端适配

**状态:** design

## 背景

MCP 官方没有 "1.0 / 2.0" 版本号(规范以日期命名),社区俗称的 **MCP 2.0**
指的是 **2026-07-28 规范**——自协议诞生以来最大的一次破坏性重写,四个官方
SDK(TS/Python/Go/C#)均已升级 v2。核心变化一句话:**从有状态会话协议,
变成普通的无状态 HTTP 负载**——无握手、无会话、按头路由、结果可缓存。

chat.nvim 现有 MCP 实现(`lua/chat/mcp/`)是纯 1.0 模式:initialize 握手三连 +
`Mcp-Session-Id` 会话管理。本方案把 2.0 的每条差异落到具体代码上。

## 差异 → 代码映射总表

| # | MCP 2.0 变化 | 现状(文件:函数) | 需要的改动 |
|---|-------------|-----------------|-----------|
| 1 | 无 initialize 握手,请求自描述 | `mcp/init.lua: connect_server()` 里 `send_initialize()` 三连(initialize → initialized 通知 → defer 1s 后 tools/list) | 新增无握手路径,直接 tools/list |
| 2 | 废除会话,`Mcp-Session-Id` 头不再需要 | `streamable_http.lua`: `session_id` 字段 + send 时回带 + close 时 DELETE | 2.0 模式全部短路(1.0 模式保留) |
| 3 | 强制 `Mcp-Method` / `Mcp-Name` 路由头,网关按头路由 | `streamable_http.lua: M.send()` 只收已编码 JSON 串,拿不到 method/name | `send` 签名加 `meta` 参数 |
| 4 | 客户端身份放 `params._meta["io.modelcontextprotocol/clientInfo"]` | 只在 initialize 的 params 里带一次 clientInfo | stateless 模式下每个请求都带 |
| 5 | `tools/list` 结果带 `ttlMs` + `cacheScope`,可缓存 | 每次 connect 后拉一次,存内存(`servers[name].tools`),重启即失,且有 1000ms defer | 新增持久缓存模块,启动即热 |
| 6 | MRTR:服务端返回 `resultType: "input_required"` + `inputRequests`,客户端带 `inputResponses` 重试 | `call_tool()` 回调只处理 `isError` / `content` 两种 | 新分支 + 重试机制 |
| 7 | 协议版本协商,当前应发最新版 | `connect_server()` 写死 `protocolVersion = '2024-11-05'` | 升级 + `MCPServer` 记录协商结果 |
| 8 | 弃用 Roots / Sampling / Logging / 旧 HTTP+SSE | **均未实现** | 零改动,`docs/mcp.md` 标注即可 |

## 方案

### 总体:一个双模客户端

不搞两套代码。同一个 `MCPServer` 增加 `stateless` 标志,连接时探测模式,
之后所有差异都收敛到 `if server.stateless then` 分支:

```
                 ┌─ stdio ──────────────→ 保留 1.0 握手(stdio 无 HTTP 头,
                 │                        握手仍是最可靠的版本协商方式)
connect_server ──┤
                 │                        发无状态 tools/list(带 2.0 头)
                 └─ streamable_http ─→ ┌─ 200 + result → stateless = true ✅
                                       └─ 400/404/JSON-RPC error
                                          → 回退 1.0 握手,stateless = false
```

1.0 服务器完全不受影响;2.0 服务器享受无状态收益;用户零配置。
也可用配置强制指定(见"配置面")。

### 改动 1:`MCPServer` 增加协议状态字段

```lua
---@class MCPServer
---@field transport table
---@field transport_type string
---@field tools MCPTool[]
---@field resources MCPResource[]
---@field stateless boolean          -- 2.0 无状态模式
---@field protocol_version string    -- 协商结果,如 '2026-07-28' / '2025-06-18'
```

### 改动 2:`send_request` 请求自描述 + meta 透传

```lua
function M.send_request(server_name, method, params, callback)
  local server = servers[server_name]
  ...
  params = params or vim.empty_dict()

  -- MCP 2.0: request self-describing via _meta
  if server.stateless then
    params._meta = params._meta or vim.empty_dict()
    params._meta['io.modelcontextprotocol/clientInfo'] = {
      name = 'chat.nvim',
      version = M._version(),
    }
  end

  local request = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params })

  -- meta 让 HTTP transport 能按 2.0 头路由
  transport_module.send(server.transport, request, {
    method = method,
    name = params.name,                     -- tools/call 的目标工具
    protocol_version = server.protocol_version,
  })
end
```

`stdio.lua` 的 `send` 忽略第三个参数即可(向后兼容,不用改)。

### 改动 3:`streamable_http.lua` 头路由

```lua
function M.send(transport, message, meta)
  meta = meta or {}

  local headers = {
    'Content-Type: application/json',
    'Accept: application/json, text/event-stream',
  }

  -- MCP 2.0 header routing (gateway/WAF 可以不解析 body)
  if meta.protocol_version then
    table.insert(headers, 'MCP-Protocol-Version: ' .. meta.protocol_version)
  end
  if meta.method then
    table.insert(headers, 'Mcp-Method: ' .. meta.method)
  end
  if meta.name then
    table.insert(headers, 'Mcp-Name: ' .. meta.name)
  end

  -- 1.0 legacy session header(2.0 无会话,session_id 本来就是 nil)
  if transport.session_id then
    table.insert(headers, 'Mcp-Session-Id: ' .. transport.session_id)
  end
  ...
```

`close()` 无需改:DELETE 分支本来就以 `transport.session_id ~= nil` 为条件,
stateless 模式下 session_id 恒为 nil,自然跳过。

### 改动 4:连接流程分叉(核心)

现有 `send_initialize()` 原样保留作 1.0 路径,新增 2.0 路径:

```lua
-- 2.0: stateless probe -- 无握手,直接带 2.0 头请求工具列表
local function send_stateless_list()
  M.send_request(name, 'tools/list', vim.empty_dict(), function(result, err)
    if err then
      log.info('[MCP:' .. name .. '] stateless mode unsupported, falling back to initialize')
      return send_initialize()   -- 探测失败 → 1.0 握手
    end
    register_tools(name, result)
  end)
end
```

要点:

- **探测请求即首个真实请求**:tools/list 成功本身就完成了"协商 + 发现",
  不需要额外 round-trip
- `send_request` 需要一个**错误回调通道**(现在 `handle_message` 收到
  `msg.error` 只打日志,不分发给 callback)。改法:`pending_requests[id]`
  增加 `on_error`,或在 callback 签名上带 `err` 参数
- HTTP 层非 200(curl 退出码非 0 且无 body)也要触发回退——需要在
  `streamable_http` 的 `on_exit` 里补一个失败上报

1.0 握手路径同时升级版本声明:

```lua
M.send_request(name, 'initialize', {
  protocolVersion = '2025-06-18',   -- 从 '2024-11-05' 升级
  ...
}, function(result)
  servers[name].protocol_version = result.protocolVersion or '2024-11-05'
  ...
```

### 改动 5:工具列表持久缓存(独立模块)

`lua/chat/mcp/cache.lua`,落盘 `stdpath('data')/chat/mcp-tools-cache.json`:

```lua
-- cache entry: { tools = MCPTool[], fetched_at = os.time(), ttl_ms = 86400000 }
M.get(server_key)      -- nil | tools(已过期的返回 nil)
M.set(server_key, tools, ttl_ms)   -- ttl_ms 优先用响应里的 ttlMs,缺省 24h
```

接入点在 `connect_server`:

```lua
-- 1. 先用缓存秒开(消除现在 1000ms defer + 异步发现的空窗期)
local cached = cache.get(cache_key)
if cached then servers[name].tools = cached end

-- 2. 后台刷新:2.0 → send_stateless_list();1.0 → 走握手后的 tools/list
-- 3. tools/list 响应处理里:cache.set(cache_key, result.tools, result.ttlMs)
```

`cache_key = server_name .. '@' .. url`(同 URL 换名字不重置缓存)。
另外顺手把 `tools/list` 后写死的 `defer_fn(..., 1000)` 干掉——等握手回调
本身就够了,1 秒魔数没有规范依据。

### 改动 6:MRTR(input_required)

服务端需要补充输入时,`tools/call` 的 result 会是:

```json
{ "resultType": "input_required",
  "inputRequests": [ { "id": "confirm-1", "prompt": "Delete prod data? [y/n]" } ] }
```

**第一版走模型驱动**:LLM 就是"补输入的人",不弹 UI:

```lua
-- call_tool 回调新增分支:
if result.resultType == 'input_required' then
  local asks = {}
  for _, r in ipairs(result.inputRequests or {}) do
    asks[#asks + 1] = string.format('- id "%s": %s', r.id, r.prompt or '')
  end
  ctx.callback({
    content = 'The MCP server requires additional input. '
      .. 'Call this tool again with the same arguments, plus '
      .. '_mcpInputResponses = [{ requestId = "<id>", value = "<answer>" }] '
      .. 'for each item:\n' .. table.concat(asks, '\n'),
    mcp_tool_call_id = current_mcp_tool_call_id,
  })
end
```

重试侧:`call_tool` 发送前检查 `arguments._mcpInputResponses`,
剥出来转成协议要求的 `inputResponses` 字段挂到 params,再发 `tools/call`。
(具体挂 params 顶层还是 `_meta`,以最终规范文本为准——见未决问题 2)

### 配置面

```lua
mcp = {
  remote = {
    url = '...',
    protocol = 'auto',    -- 默认。'2.0' | '2026-07-28' 强制无状态;
                          -- '1.0' | '2025-06-18' | '2024-11-05' 强制握手
  },
}
```

`detect_transport_type()` 旁边加一个 `resolve_protocol()`(auto 只对
HTTP 传输有意义;stdio 恒握手)。

### 分阶段落地

| 阶段 | 内容 | 风险 |
|------|------|------|
| P1 | 改动 1+2+3:meta 透传、`MCPServer` 字段、头构造。纯结构重构,零行为变化 | 低 |
| P2 | 改动 4:双路径连接 + 协商回退 + initialize 版本升级 | 中 |
| P3 | 改动 5:缓存模块 + 去掉 1s defer | 低 |
| P4 | 改动 6:MRTR 模型驱动重试 | 中 |
| P5 | `docs/mcp.md` 更新(2.0 说明、protocol 配置、弃用项标注) | 低 |

P1/P2 合一个 PR,P3、P4 各一个。

## 设计决策

1. **双模共存,而非整体迁移。** 生态里 1.0 服务器仍是存量大头,直接切 2.0
   会断掉现有用户配置。auto 协商让用户零感知。
2. **探测即首个真实请求。** 有人会想先发个 ping 之类探测 2.0 支持,浪费
   round-trip;直接拿 tools/list 当探测,成功即完成发现。
3. **MRTR 第一版模型驱动。** 另一个选项是弹 UI 让用户答(更像传统
   elicitation),但要动 chat window 渲染、阻塞异步队列,复杂度上一档。
   模型驱动复用现有 tool call 回环,零 UI 改动,先验证协议层。
4. **缓存默认 24h TTL 而非永久。** tools/list 是"提示性"的(列表过期只影响
   新会话可见性,不影响已注册工具调用),宁可多拉一次也不要陈旧列表。
   响应里带 `ttlMs` 就听服务器的。
5. **stdio 不做无状态。** 头路由、缓存提示这些收益都是 HTTP 侧的;stdio
   的 initialize 握手开销可忽略(本地进程),保留握手反而获得最可靠的
   版本协商。
6. **`send` 第三参数可选。** 所有第三方 transport 注册(如果有人写过自定义
   transport)不会被签名变更炸掉。

## 风险 / 未决问题

- **规范仍新鲜。** 2026-07-28 发布不久,`Mcp-Method` / `Mcp-Name` /
  `_meta` 键名、`inputResponses` 的确切位置,落地前必须以官方规范文本
  逐字核对,别照博客抄。头部大小写(HTTP header 大小写不敏感,但保守起见
  与规范一致)。
- **协商对老服务器多一次失败请求。** 1.0 服务器会收到一个不认识的
  stateless 请求,多消耗一个 round-trip + 一条错误日志。可接受;若服务器
  对未知请求返回非幂等错误(如直接断连),需要容错。
- **MRTR 的状态生命周期。** `input_required` 后服务端有没有超时窗口?
  用户隔很久才让模型重试,句柄是否失效?协议层存疑,先按"失效就报错给
  模型"处理。
- **缓存失效与工具调用的一致性。** 缓存列表过期后工具签名变了,模型还按
  旧 schema 调用会报错——这本来就是 1.0 也有的问题(注册后不刷新),
  缓存不恶化它,但值得在文档里写明"重启会话或 `:Chat mcp restart` 刷新"。
- **curl 多值头。** 自定义 headers 和新加的协议头都走 `-H` 数组,
  `curl.build_request` 已支持列表,无风险;但注意别让用户自定义 headers
  覆盖 `Mcp-Method` 之类的协议头(发送时协议头放最后覆盖)。

## 测试要点

headless 环境起不了真 MCP server,把纯逻辑抽干净再测
(`test/mcp2_spec.lua`,照 `config.setup({ storage_dir = temp })` 惯例):

- **头构造**:抽取 `streamable_http._build_headers(meta, transport)`,
  断言 2.0 meta 产出三个头、1.0 只产 session 头、用户自定义头不覆盖协议头
- **协商状态机**:`handle_message` 喂 mock 响应——2.0 result → stateless
  生效;JSON-RPC error → 触发 `send_initialize` 回退;1.0 initialize result
  → protocol_version 记录正确
- **`_meta` 注入**:stateless 请求的 params 带 clientInfo,1.0 请求不带
- **缓存**:写 → 读命中;`fetched_at + ttl` 过期 → miss;ttlMs 来自响应
- **MRTR**:result 喂 `input_required` → ctx.callback 拿到的 content 含
  prompt 和 id;重试调用带 `_mcpInputResponses` → 发出的 params 里被
  正确转换为 `inputResponses`
- **回归**:现有 `mcp_test_search` scheme 消毒用例(`tools/general_spec.lua`)
  不受影响

## 落地范围

- `lua/chat/mcp/init.lua` —— 主改动(双路径、_meta、MRTR、缓存接入)
- `lua/chat/mcp/transport/streamable_http.lua` —— 头路由、失败上报
- `lua/chat/mcp/transport/stdio.lua` —— 仅忽略 send 第三参数(或不动)
- `lua/chat/mcp/cache.lua` —— 新文件
- `docs/mcp.md` —— P5 文档
- `ideas/README.md` —— 状态追踪


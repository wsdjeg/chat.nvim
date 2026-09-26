# 001 - 项目级工具目录(按会话 cwd 发现)

**状态:** design

## 动机

工作助手场景:会话的 cwd 是一个 working 目录,用户(或 AI)想在这个目录里新建一个工具,**只对 cwd 在这个目录的会话可用**,其他会话(其他 cwd)不可见、不可调用。工具文件跟着工作目录走,可进 git 团队共享。

现状只能把工具写进插件本体(`lua/chat/tools/*.lua`)—— 全局生效,粒度不匹配;或用 MCP server —— 太重,要单独进程。

## 方案

目录约定 + 按会话 cwd 动态发现:

```
<cwd>/.chat/tools/*.lua     ← 一个文件一个工具
       │
       │  request_tools(session_id)
       │  → 从 storage.sessions[id].cwd 拿 cwd
       │  → 扫描 <cwd>/.chat/tools/ → loadfile → 校验 → 合并进请求
       ▼
只有 cwd 匹配的会话看得到;M.call 时按 ctx.cwd 路由到它
```

隔离性来自**目录即边界**:工具文件只存在于那个 working 目录,其他 cwd 的会话扫描不到。

### 工具文件格式

与内置工具约定完全一致,零新概念:

```lua
-- <working_dir>/.chat/tools/deploy_staging.lua
local M = {}

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'deploy_staging',
      description = 'Deploy current branch to staging (ops only)',
      parameters = {
        type = 'object',
        properties = {
          confirm = { type = 'boolean', description = 'Must be true' },
        },
        required = { 'confirm' },
      },
    },
  }
end

function M.deploy_staging(action, ctx)
  if not action.confirm then
    return { error = 'confirm=true required' }
  end
  return { content = 'deployed to staging' }
end

function M.info(action)
  return 'deploy_staging(...)'
end

return M
```

`scheme()` + `M.<name>(action, ctx)` + 可选 `info()`,复用 `validate_scheme`。

### 核心实现(`lua/chat/tools.lua` 追加 ~80 行)

```lua
-- dir -> { sig = string, tools = { [name] = module } }
-- 缓存按目录而非 session:同 working 目录的会话共享一次加载
local project_tools_cache = {}

local function load_project_tools(cwd)
  if not cwd or cwd == '' then
    return {}
  end
  local cfg = require('chat.config').config.tools or {}
  if cfg.project == false then
    return {}
  end

  local dir = vim.fs.normalize(cwd) .. '/.chat/tools'
  local files = vim.fs.find('*.lua', { path = dir, maxdepth = 1 })
  if #files == 0 then
    project_tools_cache[dir] = nil
    return {}
  end
  table.sort(files)

  -- 签名 = 文件列表 + size + mtime:文件新建/修改后自动重载
  local parts = {}
  for _, f in ipairs(files) do
    local stat = vim.uv.fs_stat(f)
    parts[#parts + 1] = ('%s:%d:%f'):format(f, stat.size, stat.mtime)
  end
  local sig = table.concat(parts, '|')
  local cached = project_tools_cache[dir]
  if cached and cached.sig == sig then
    return cached.tools
  end

  -- 全局工具名集合,用于冲突检查
  local global_names = {}
  for _, s in ipairs(M.available_tools()) do
    global_names[s['function'].name] = true
  end

  local tools = {}
  for _, f in ipairs(files) do
    local chunk, err = loadfile(f)
    if not chunk then
      log.warn('project tool load failed: ' .. f .. ': ' .. tostring(err))
    else
      local ok, mod = pcall(chunk)
      local scheme_ok, scheme = pcall(function() return mod and mod.scheme() end)
      local name = ok and scheme_ok and scheme
        and scheme['function'] and scheme['function'].name
      if not (ok and type(mod) == 'table' and name) then
        log.warn('project tool invalid (need scheme() with function.name): ' .. f)
      elseif name:match('^mcp_') or name == 'find_tool' then
        log.warn('project tool reserved name, skipped: ' .. name)
      elseif #M.validate_scheme(scheme) > 0 then
        log.warn('project tool scheme invalid: ' .. name)
      elseif global_names[name] then
        log.warn('project tool name conflicts with global tool, skipped: ' .. name)
      elseif type(mod[name]) ~= 'function' then
        log.warn('project tool missing handler M.' .. name .. '(): ' .. f)
      else
        tools[name] = mod
      end
    end
  end
  project_tools_cache[dir] = { sig = sig, tools = tools }
  return tools
end

--- Schemes of project tools for a cwd (for request building).
local function project_tool_schemes(cwd)
  local schemes = {}
  for _, mod in pairs(load_project_tools(cwd)) do
    table.insert(schemes, mod.scheme())
  end
  return schemes
end
```

### 注入点

**① `request_tools(session_id)`** —— 两个分支都加。cwd 从 storage 拿
(照抄 `scan_history_tool_names` 的 lazy require 模式):

```lua
  local cwd
  do
    local ok, storage = pcall(require, 'chat.sessions.storage')
    if ok and storage and storage.sessions[session_id] then
      cwd = storage.sessions[session_id].cwd
    end
  end

  if cfg.lazy == false then
    local tools = M.available_tools()
    vim.list_extend(tools, project_tool_schemes(cwd))
    return tools
  end
  -- ... lazy 分支 find_tool 之后追加:
  for _, scheme in ipairs(project_tool_schemes(cwd)) do
    if not seen[scheme['function'].name] then
      seen[scheme['function'].name] = true
      table.insert(selected, scheme)
    end
  end
```

**②③ `M.call` / `M.info` 开头** —— `ctx.cwd` 直接可用。
优先级:项目工具 > MCP > 内置(最特异优先):

```lua
function M.call(func, arguments, ctx)
  local pt = load_project_tools(ctx and ctx.cwd)
  if pt[func] and type(pt[func][func]) == 'function' then
    return pt[func][func](arguments, ctx)
  end
  -- ... 现有 mcp_/内置逻辑不变
```

## 设计决策

1. **隔离粒度是 cwd,不是 session_id。** 同一个 working 目录的多个会话共享
   这些工具(扫描和缓存都按目录来)。"只对这个会话有用"的本质是"只对这类
   (cwd 相同的)会话有用"。若要严格到单会话,需 session.json 记清单,复杂度
   上一档,一般没必要。

2. **不走 find_tool catalog,直接随请求发送。** catalog 是全局的、无 session
   维度,改它会污染所有会话的 find_tool description。项目工具数量少(通常
   1~5 个),直接发送完整 schema,语义也更对:专属工具必须开箱即用,不该靠发现。

3. **mtime 签名缓存 → 热更新。** 会话中用 write_file 写出
   `.chat/tools/xxx.lua`,下一轮请求签名变化自动重载,立刻可调用。

4. **与全局工具重名 → 跳过 + warn。** 不允许覆盖,避免模型对同名工具的
   行为产生混乱。

## 风险 / 未决问题

- **安全:** 执行 working 目录里的任意 Lua = clone 陌生仓库 + 打开会话
  = 自动执行其中代码。与 Neovim 对 exrc 的信任问题同类。缓解:
  - config 开关 `tools.project = false` **默认关闭**,显式打开才生效
  - 文档写明只放可信来源的工具文件
  - 可选增强:目录有工具但开关关闭时,log 提示"发现 N 个项目工具未启用"
  - 以后可加 trust 机制(类似 `:h :trust`)
- 每个失败路径(语法错误、scheme 非法、名字冲突、缺 handler)都是 warn +
  跳过,单个坏文件不影响其余工具和整个请求。
- 待定:`.chat/` 目录是否推广为项目级配置的统一位置(prompt、skills 等)?

## 测试要点

`test/tools/project_tools_spec.lua`:

- temp 目录 A 放工具 → `tools.call('x', {}, { cwd = A })` 路由成功;
  `cwd = B` → `unknown tool function name.`
- 造两个 session(不同 cwd)→ `request_tools` 各自只含自己 cwd 的工具
- 语法错误文件 → 共存工具照常加载
- 与全局工具重名 / `mcp_` 前缀 / `find_tool` 名 → 跳过
- 修改文件(改变 size)→ 重载生效
- `tools.project = false` → 不加载
- 照规矩 `config.setup({ storage_dir = temp })` 起隔离环境

## 落地范围

改动全部集中在 `lua/chat/tools.lua` 一个文件,协议层零改动。
新增文档一篇(`docs/usage/` 或 `docs/api/`)+ `ideas/README.md` 状态更新。


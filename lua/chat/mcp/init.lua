local M = {}

local log = require('chat.log')
local config = require('chat.config')

local job = require('job')

---@class MCPServer
---@field jobid number
---@field tools MCPTool[]
---@field resources MCPResource[]
---@field pending_requests table<number, {callback: function}>

---@class MCPTool
---@field name string
---@field description string
---@field inputSchema table

local servers = {} ---@type table<string, MCPServer>
local request_id = 0
local pending_requests = {}

-- 初始化 MCP
function M.setup()
  local mcp_config = config.config.mcp or {}

  for server_name, server_config in pairs(mcp_config) do
    if not server_config.disabled then
      M.connect_server(server_name, server_config)
    end
  end
end

-- 连接到 MCP server
function M.connect_server(name, server_config)
  local cmd = { server_config.command }
  if server_config.args then
    vim.list_extend(cmd, server_config.args)
  end

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      M.handle_stdout(name, data)
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        log.error('[MCP:' .. name .. '] ' .. v)
      end
    end,
    on_exit = function(_, code, single)
      log.warn(
        '[MCP:'
          .. name
          .. '] Server exited with code '
          .. code
          .. ' single '
          .. single
      )
      servers[name] = nil
    end,
    env = server_config.env,
  })

  if jobid > 0 then
    servers[name] = {
      jobid = jobid,
      tools = {},
      resources = {},
      pending_requests = {},
    }

    -- 发送 initialize 请求
    M.send_request(name, 'initialize', {
      protocolVersion = '2024-11-05',
      capabilities = vim.empty_dict(),
      clientInfo = {
        name = 'chat.nvim',
        version = '1.0.0',
      },
    }, function(result)
      -- 发送 initialized 通知（MCP 协议要求）
      M.send_notification(name, 'initialized', vim.empty_dict())

      -- 延迟后请求工具列表
      vim.defer_fn(function()
        M.send_request(
          name,
          'tools/list',
          vim.empty_dict(),
          function(list_result)
            if list_result.tools then
              servers[name].tools = list_result.tools
              log.info(
                '[MCP:'
                  .. name
                  .. '] Registered '
                  .. #list_result.tools
                  .. ' tools'
              )
            else
              log.warn('[MCP:' .. name .. '] No tools found')
            end
          end
        )
      end, 100)
    end)

    log.info('[MCP] Connected to server: ' .. name)
  else
    log.error('[MCP] Failed to start server: ' .. name)
  end
end

-- 发送 JSON-RPC 请求
function M.send_request(server_name, method, params, callback)
  local server = servers[server_name]
  if not server then
    log.error('[MCP] Server not found: ' .. server_name)
    return nil, 'Server not found'
  end

  request_id = request_id + 1
  local id = request_id

  if callback then
    pending_requests[id] = {
      server = server_name,
      callback = callback,
    }
  end

  local request = vim.json.encode({
    jsonrpc = '2.0',
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }) .. '\n'

  job.send(server.jobid, request)
  return id
end

-- 发送 JSON-RPC 通知（无需响应）
function M.send_notification(server_name, method, params)
  local server = servers[server_name]
  if not server then
    log.error('[MCP] Server not found: ' .. server_name)
    return
  end

  local notification = vim.json.encode({
    jsonrpc = '2.0',
    method = method,
    params = params or vim.empty_dict(),
  }) .. '\n'

  job.send(server.jobid, notification)
end

-- 处理 stdout 数据
function M.handle_stdout(server_name, data)
  local data_str = table.concat(data, '\n')

  for line in data_str:gmatch('[^\r\n]+') do
    if line:sub(1, 1) == '{' then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        M.handle_message(server_name, msg)
      else
        log.error('[MCP:' .. server_name .. '] JSON decode failed: ' .. line)
      end
    end
  end
end

-- 处理 JSON-RPC 消息
function M.handle_message(server_name, msg)
  -- Response
  if msg.id and pending_requests[msg.id] then
    local request = pending_requests[msg.id]
    pending_requests[msg.id] = nil

    if msg.result and request.callback then
      request.callback(msg.result)
    elseif msg.error then
      log.error(
        '[MCP:'
          .. server_name
          .. '] Request error: '
          .. (msg.error.message or 'unknown')
      )
    end

  -- Notification
  elseif msg.method then
    log.debug('[MCP:' .. server_name .. '] Notification: ' .. msg.method)
  end
end

-- 辅助函数：从已注册的 tools 中查找服务器名
-- 解决服务器名包含下划线的问题（如 open_webSearch）
local function find_server_for_tool(full_tool_name)
  -- 方案1：从已注册的 tools 列表中查找（最准确）
  for server_name, server in pairs(servers) do
    for _, mcp_tool in ipairs(server.tools) do
      if full_tool_name == 'mcp_' .. server_name .. '_' .. mcp_tool.name then
        return server_name, mcp_tool.name
      end
    end
  end

  -- 方案2：从末尾解析最后一个下划线（备选方案，兼容未来可能的格式变化）
  -- mcp_open_webSearch_search -> server: "open_webSearch", tool: "search"
  -- 使用贪婪匹配，server_name 匹配尽可能多的内容
  local server_name, mcp_tool_name = full_tool_name:match('^mcp_(.+)_(.-)$')
  if server_name and mcp_tool_name then
    -- 验证服务器是否存在
    if servers[server_name] then
      return server_name, mcp_tool_name
    end
  end

  return nil, nil
end

-- 调用 MCP tool
function M.call_tool(tool_name, arguments, ctx)
  -- 查找 server 名称和 tool 名称
  local server_name, mcp_tool_name = find_server_for_tool(tool_name)

  if not server_name or not mcp_tool_name then
    return { error = 'Invalid MCP tool name format: ' .. tool_name }
  end

  local server = servers[server_name]
  if not server then
    return { error = 'MCP server not found: ' .. server_name }
  end

  -- 发送 tools/call 请求（异步）
  local co = coroutine.running()
  local result_received = false
  local tool_result = nil

  M.send_request(server_name, 'tools/call', {
    name = mcp_tool_name,
    arguments = arguments,
  }, function(result)
    result_received = true
    tool_result = result
    if co then
      coroutine.resume(co)
    end
  end)

  -- 如果在协程中，等待结果
  if co then
    coroutine.yield()
  else
    -- 同步等待（使用 vim.wait）
    vim.wait(30000, function()
      return result_received
    end, 100)
  end

  if not tool_result then
    return { error = 'MCP tool call timeout or failed' }
  end

  -- 处理 MCP tool 结果格式
  if tool_result.content then
    local content_parts = {}
    for _, part in ipairs(tool_result.content) do
      if part.type == 'text' then
        table.insert(content_parts, part.text)
      end
    end
    return {
      content = table.concat(content_parts, '\n'),
    }
  elseif tool_result.isError then
    return {
      error = tool_result.isError or 'MCP tool call failed',
    }
  else
    return { content = vim.inspect(tool_result) }
  end
end

-- 获取所有 MCP tools（转换为 chat.nvim 格式）
function M.available_tools()
  local tools = {}

  for server_name, server in pairs(servers) do
    for _, mcp_tool in ipairs(server.tools) do
      table.insert(tools, {
        type = 'function',
        ['function'] = {
          name = 'mcp_' .. server_name .. '_' .. mcp_tool.name,
          description = '[MCP:'
            .. server_name
            .. '] '
            .. mcp_tool.description,
          parameters = mcp_tool.inputSchema,
        },
      })
    end
  end

  return tools
end

-- 检查是否是 MCP tool
function M.is_mcp_tool(tool_name)
  return tool_name:match('^mcp_[^_]+_.+$') ~= nil
end

-- 获取 MCP tool 的信息描述
function M.tool_info(tool_name, arguments_str)
  -- 查找 server 名称和 tool 名称
  local server_name, mcp_tool_name = find_server_for_tool(tool_name)

  if not server_name or not mcp_tool_name then
    return tool_name
  end

  -- 尝试解析 arguments JSON
  local args_info = ''
  local ok, arguments = pcall(vim.json.decode, arguments_str or '{}')
  if ok and arguments then
    -- 简单显示关键参数
    local parts = {}
    for key, value in pairs(arguments) do
      if type(value) == 'string' then
        table.insert(parts, string.format('%s="%s"', key, value))
      elseif type(value) == 'number' or type(value) == 'boolean' then
        table.insert(parts, string.format('%s=%s', key, value))
      end
    end
    if #parts > 0 then
      args_info = ' ' .. table.concat(parts, ' ')
    end
  end

  return string.format('mcp_%s_%s%s', server_name, mcp_tool_name, args_info)
end

return M

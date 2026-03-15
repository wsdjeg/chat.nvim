local M = {}

local job = require('job')
local log = require('chat.log')

---@class StdioTransport
---@field jobid number
---@field server_name string
---@field on_message function

-- Create stdio transport
---@param server_name string
---@param config table { command: string, args?: string[], env?: table }
---@param on_message function(msg: table)
---@return table|nil transport, string|nil error
function M.create(server_name, config, on_message)
  if not config.command then
    return nil, 'stdio transport requires "command" field'
  end

  local cmd = { config.command }
  if config.args then
    vim.list_extend(cmd, config.args)
  end

  local transport = {
    type = 'stdio',
    jobid = nil,
    server_name = server_name,
    on_message = on_message,
  }

  transport.jobid = job.start(cmd, {
    on_stdout = function(_, data)
      local data_str = table.concat(data, '\n')
      for line in data_str:gmatch('[^\r\n]+') do
        if line:sub(1, 1) == '{' then
          local ok, msg = pcall(vim.json.decode, line)
          if ok then
            on_message(msg)
          else
            log.error(
              '[MCP:' .. server_name .. '] JSON decode failed: ' .. line
            )
          end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        log.error('[MCP:' .. server_name .. '] ' .. v)
      end
    end,
    on_exit = function(_, code, single)
      log.warn(
        '[MCP:'
          .. server_name
          .. '] Server exited with code '
          .. code
          .. ' single '
          .. single
      )
      transport.jobid = nil
      if config.on_disconnect then
        config.on_disconnect()
      end
    end,
    env = config.env,
  })

  if not transport.jobid or transport.jobid <= 0 then
    return nil, 'Failed to start server: ' .. server_name
  end

  log.info('[MCP] Connected to server via stdio: ' .. server_name)
  return transport, nil
end

-- Send raw message
---@param transport table
---@param message string
function M.send(transport, message)
  if transport.jobid then
    job.send(transport.jobid, message)
  end
end

-- Close transport
---@param transport table
function M.close(transport)
  if transport.jobid then
    job.stop(transport.jobid, 2)
    transport.jobid = nil
  end
end

return M

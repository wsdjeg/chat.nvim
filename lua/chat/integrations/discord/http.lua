-- lua/chat/integrations/discord/http.lua
-- One authenticated request runner for the Discord REST API.
--
-- Kept separate from poll.lua / send.lua because every request shares the same
-- three concerns: the Bot token header, the stdin-vs-inline body decision, and
-- the mapping of curl's exit code onto a human-readable failure reason.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local util = require('chat.integrations.discord.util')

local json = vim.json

local M = {}

--- Run a request against the Discord API.
---
--- `callback(result, err)` fires exactly once when the request settles:
--- `result` is the decoded JSON body (nil on failure), `err` is a
--- human-readable reason. A request that could not even be started returns a
--- non-positive jobid and never calls back -- callers that keep a lock must
--- check the return value.
---
--- @param method string HTTP method
--- @param endpoint string path appended to `util.API_BASE`, with query string
--- @param data table|nil request body (nil for GET/DELETE without a body)
--- @param callback fun(result: table|nil, err: string|nil)
--- @return integer|nil jobid
function M.request(method, endpoint, data, callback)
  local token = util.token()
  if not token then
    log.error('[Discord] Token not configured')
    return nil
  end

  local cmd = curl.build_request({
    url = util.API_BASE .. endpoint,
    method = method,
    headers = {
      'Authorization: Bot ' .. token,
      'Content-Type: application/json',
    },
    -- Only read the body from stdin when there IS one. A GET with `-d @-`
    -- blocks curl reading stdin until EOF, but stdin is only closed by
    -- `job.send(jobid, nil)` below -- which never runs for `data == nil`.
    -- curl would then hang forever: `--max-time` cannot help because the
    -- `-d` data is slurped before the transfer even starts.
    stdin_body = data ~= nil,
    connect_timeout = util.CONNECT_TIMEOUT,
    max_time = util.MAX_TIME,
  })

  local stdout, stderr = {}, {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, lines)
      for _, v in ipairs(lines) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(_, lines)
      -- Collected instead of logged: curl writes network errors to stderr even
      -- with -s, and per-line logging would spam every poll while the network
      -- is down.
      for _, line in ipairs(lines) do
        if line and line ~= '' then
          table.insert(stderr, line)
        end
      end
    end,
    on_exit = function(_, code, signal)
      if not callback then
        return
      end

      if code ~= 0 or signal ~= 0 then
        local reason = 'curl exited with code ' .. code
        if #stderr > 0 then
          reason = reason .. ': ' .. table.concat(stderr, ' ')
        end
        return callback(nil, reason)
      end

      local output = table.concat(stdout, '\n')
      if output == '' then
        return callback(nil, 'empty response')
      end

      local ok, result = pcall(json.decode, output)
      if not ok or result == nil then
        return callback(nil, 'invalid JSON: ' .. output:sub(1, 120))
      end
      callback(result)
    end,
  })

  if data then
    job.send(jobid, json.encode(data))
    job.send(jobid, nil)
  end

  return jobid
end

return M


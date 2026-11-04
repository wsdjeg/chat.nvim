-- lua/chat/lark/auth.lua
-- Shared Lark (Feishu) tenant_access_token cache.
--
-- The IM integration (integrations/lark.lua) and the bitable tool both need a
-- tenant token. Keeping a single cache means one refresh request instead of
-- two, and one place that knows the expiry/renewal rule.
--
-- The token is resolved as soon as a complete JSON payload arrives on stdout
-- (and, as a fallback, on exit): the IM integration only feeds stdout in the
-- existing specs, and waiting for the exit callback there would stall the
-- polling flow.
local M = {}

local config = require('chat.config')
local curl = require('chat.curl')
local job = require('job')

local API_BASE = 'https://open.feishu.cn/open-apis'

local state = {
  token = nil,
  expires_at = 0,
}

--- Credentials from config.integrations.lark, or nil when incomplete.
--- @return table|nil
local function credentials()
  local lark = config.config.integrations
    and config.config.integrations.lark
  if not lark or not lark.app_id or not lark.app_secret then
    return nil
  end
  return lark
end

--- Drop the cached token.
--- Used by tests, and after an auth failure so the next call re-fetches.
function M.reset()
  state.token = nil
  state.expires_at = 0
end

--- Seed the cache without a network round-trip (internal export for tests,
--- same convention as tools' `_reset_availability_cache`).
--- @param token string
--- @param expires_in? integer Seconds until expiry (default: 7200)
function M._set_token(token, expires_in)
  state.token = token
  state.expires_at = os.time() + (expires_in or 7200)
end

--- Cached token while still valid, otherwise nil.
--- @return string|nil
function M.cached_token()
  if state.token and os.time() < state.expires_at then
    return state.token
  end
  return nil
end

--- Request a fresh tenant_access_token.
--- @param callback fun(token: string|nil, err: string|nil)
--- @return integer|nil jobid
function M.fetch_token(callback)
  local lark = credentials()
  if not lark then
    callback(nil, 'lark app_id or app_secret not configured')
    return nil
  end

  local done = false
  local function finish(token, err)
    if done then
      return
    end
    done = true
    callback(token, err)
  end

  local cmd = curl.build_request({
    url = API_BASE .. '/auth/v3/tenant_access_token/internal',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
    },
    body = vim.json.encode({
      app_id = lark.app_id,
      app_secret = lark.app_secret,
    }),
  })

  local chunks = {}
  local jobid = job.start(cmd, {
    on_stdout = function(_, lines)
      for _, line in ipairs(lines) do
        chunks[#chunks + 1] = line
      end
      -- Resolve as soon as the payload is complete, so callers that only
      -- stream stdout (and the polling timer) are not blocked until exit.
      local output = table.concat(chunks, '\n')
      local ok, result = pcall(vim.json.decode, output)
      if ok and type(result) == 'table' and result.tenant_access_token then
        state.token = result.tenant_access_token
        state.expires_at = os.time() + (result.expire or 7200) - 300
        finish(state.token)
      end
    end,
    on_exit = function(_, code, signal)
      if done then
        return
      end
      if signal ~= 0 then
        finish(nil, 'token request cancelled')
        return
      end
      local output = table.concat(chunks, '\n')
      local ok, result = pcall(vim.json.decode, output)
      if code ~= 0 or not ok or type(result) ~= 'table' then
        finish(nil, 'failed to obtain tenant_access_token: ' .. output)
        return
      end
      if not result.tenant_access_token then
        finish(nil, 'tenant_access_token missing in response: ' .. output)
        return
      end
      state.token = result.tenant_access_token
      state.expires_at = os.time() + (result.expire or 7200) - 300
      finish(state.token)
    end,
  })

  if not jobid or jobid <= 0 then
    finish(nil, 'failed to start token request')
    return nil
  end

  return jobid
end

--- Usable token, refreshing it when the cache is cold.
--- @param callback fun(token: string|nil, err: string|nil)
function M.ensure_token(callback)
  local token = M.cached_token()
  if token then
    callback(token)
    return
  end
  M.fetch_token(callback)
end

return M


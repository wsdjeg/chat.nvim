-- lua/chat/sessions/cache_probe.lua
-- Prefix-cache observability.
--
-- Provider prompt caching only pays off while the request prefix stays
-- byte-identical: system prompt + tools + the messages already sent. This
-- module fingerprints each request and reports the first position where it
-- diverges from the previous request of the same session, so a regression
-- (tools reshuffled, dynamic content back at the head, window sliding every
-- turn) shows up in the log instead of only on the bill.
--
-- Wiring (each hook is best-effort, a probe failure never breaks a request):
--   * chat.protocol.request  -> begin_request(session, messages)
--   * chat.tools.request_tools -> record_tools(session, schemes)
--   * progress.set_progress_usage -> record_usage(session, usage)
--
-- Vocabulary used in the log line:
--   append  the previous prefix is intact, only new messages were added
--           (the healthy case for an ongoing turn)
--   system  the leading system block changed
--   tools   the tools array changed (order or membership)
--   messages an already-sent message was rewritten or the window moved
--   truncated the request got shorter than the previous one (windowing)

local M = {}

local log = require('chat.log')
local usage_util = require('chat.usage')

-- Bytes of a string that take part in the fingerprint. Tool outputs can be
-- huge; the head is enough to detect changes, and the length is mixed in so
-- a truncated string cannot look like a longer one with the same head.
local SAMPLE_BYTES = 4096

-- 32-bit-ish polynomial hash using only arithmetic (no bit library, no
-- integer division): stable across platforms and Lua versions.
---@param s any
---@return string fingerprint
local function hash_string(s)
  if type(s) ~= 'string' then
    return '0'
  end
  local n = #s
  local h = 2166136261
  local limit = n < SAMPLE_BYTES and n or SAMPLE_BYTES
  for i = 1, limit do
    h = (h * 31 + s:byte(i)) % 4294967296
  end
  h = (h * 31 + n) % 4294967296
  return tostring(h)
end

M.hash_string = hash_string

--- Fingerprint one request message: role, content, tool call names and
--- arguments, tool_call_id. reasoning_content is deliberately excluded -
--- most providers do not resend it, so counting it would report phantom
--- breaks.
---@param m table
---@return string
local function hash_message(m)
  local parts = { m.role or '' }
  if type(m.content) == 'string' then
    parts[#parts + 1] = m.content
  end
  if type(m.tool_call_id) == 'string' then
    parts[#parts + 1] = m.tool_call_id
  end
  if type(m.tool_calls) == 'table' then
    local tcs = {}
    for _, tc in ipairs(m.tool_calls) do
      local fn = type(tc['function']) == 'table' and tc['function'] or {}
      tcs[#tcs + 1] = tostring(tc.id or '')
      tcs[#tcs + 1] = tostring(fn.name or '')
      tcs[#tcs + 1] = tostring(fn.arguments or '')
    end
    parts[#parts + 1] = table.concat(tcs, '\1')
  end
  return hash_string(table.concat(parts, '\2'))
end

M.hash_message = hash_message

--- Per-session previous request fingerprint (the comparison baseline).
local previous = {} ---@type table<string, table>
--- Per-session request whose messages are known but whose tools array has
--- not been recorded yet.
local pending = {} ---@type table<string, table>
--- Per-session counters.
local stats = {} ---@type table<string, table>

local function new_stats()
  return {
    requests = 0,
    appends = 0,
    breaks = 0,
    prompt_tokens = 0,
    cached_tokens = 0,
    last_reason = nil,
    last_break_index = nil,
  }
end

--- Whether the probe is enabled (config.cache.probe ~= false).
---@return boolean
function M.enabled()
  local ok, config = pcall(require, 'chat.config')
  if not ok or not config or type(config.config) ~= 'table' then
    return true
  end
  local cache = config.config.cache
  if type(cache) ~= 'table' then
    return true
  end
  return cache.probe ~= false
end

--- Record the messages of a request that is about to be sent. Providers add
--- the tools array afterwards, which finalizes the comparison.
--- @param session_id string
--- @param messages table[]
function M.begin_request(session_id, messages)
  if not session_id or type(messages) ~= 'table' or not M.enabled() then
    return
  end

  -- A previous request whose provider never asked for tools would otherwise
  -- stay pending forever: finalize it now (tools = unknown) so its
  -- fingerprints still take part in the comparison.
  if pending[session_id] then
    M._finalize(session_id, nil)
  end

  local hashes = {}
  local system_parts = {}
  local in_system = true
  for _, m in ipairs(messages) do
    if in_system and m.role == 'system' then
      system_parts[#system_parts + 1] = hash_message(m)
    else
      in_system = false
    end
    hashes[#hashes + 1] = hash_message(m)
  end

  pending[session_id] = {
    system = hash_string(table.concat(system_parts, '\1')),
    hashes = hashes,
    count = #messages,
  }
end

--- Record the tools array that goes into the request body and finalize the
--- comparison against the previous request of the session.
--- @param session_id string
--- @param tools table[]|nil Tool schemes in request order
function M.record_tools(session_id, tools)
  if not session_id or not M.enabled() then
    return
  end
  local names = {}
  if type(tools) == 'table' then
    for _, scheme in ipairs(tools) do
      local fn = type(scheme) == 'table' and scheme['function'] or nil
      names[#names + 1] = (type(fn) == 'table' and fn.name) or '?'
    end
  end
  M._finalize(session_id, hash_string(table.concat(names, ',')))
end

--- Compare the pending request with the previous one and log the outcome.
--- @param session_id string
--- @param tools_hash string|nil Fingerprint of the tools array
function M._finalize(session_id, tools_hash)
  local current = pending[session_id]
  if not current then
    return
  end
  pending[session_id] = nil
  current.tools = tools_hash

  local s = stats[session_id]
  if not s then
    s = new_stats()
    stats[session_id] = s
  end
  s.requests = s.requests + 1

  local prev = previous[session_id]
  previous[session_id] = current

  if not prev then
    log.debug(string.format(
      '[cache] session=%s req=#%d messages=%d system=%s tools=%s (baseline)',
      session_id, s.requests, current.count, current.system,
      tostring(current.tools)
    ))
    return
  end

  local reason, break_index
  if prev.tools ~= current.tools then
    reason = 'tools'
  elseif prev.system ~= current.system then
    reason = 'system'
  else
    local shared = #prev.hashes < #current.hashes and #prev.hashes
      or #current.hashes
    break_index = shared + 1
    for i = 1, shared do
      if prev.hashes[i] ~= current.hashes[i] then
        break_index = i
        break
      end
    end
    if break_index <= shared then
      reason = 'messages'
    elseif #current.hashes < #prev.hashes then
      reason = 'truncated'
    else
      reason = 'append'
    end
  end

  if reason == 'append' then
    s.appends = s.appends + 1
    log.debug(string.format(
      '[cache] session=%s req=#%d append +%d messages, prefix intact (%d)',
      session_id, s.requests, #current.hashes - #prev.hashes, #prev.hashes
    ))
    return
  end

  s.breaks = s.breaks + 1
  s.last_reason = reason
  s.last_break_index = break_index
  log.info(string.format(
    '[cache] session=%s req=#%d break=#%s/%d reason=%s '
      .. '(messages before the break stay cached)',
    session_id, s.requests, tostring(break_index or 1), current.count, reason
  ))
end

--- Accumulate provider-reported token counts so `stats()` can report a
--- cache hit ratio. Providers that report nothing simply keep it at 0.
--- Cached-token extraction lives in `chat.usage` so every UI surface reads
--- the provider payload the same way.
--- @param session_id string
--- @param usage table|nil
function M.record_usage(session_id, usage)
  if not session_id or not M.enabled() then
    return
  end
  local u = usage_util.normalize(usage)
  if u.prompt_tokens <= 0 and u.cached_tokens <= 0 then
    return
  end
  local s = stats[session_id]
  if not s then
    s = new_stats()
    stats[session_id] = s
  end
  s.prompt_tokens = s.prompt_tokens + u.prompt_tokens
  s.cached_tokens = s.cached_tokens + u.cached_tokens
end

--- Cache probe statistics for a session.
--- @param session_id string
--- @return table stats { requests, appends, breaks, breaks_per_request,
---   prompt_tokens, cached_tokens, hit_ratio, last_reason, last_break_index }
function M.stats(session_id)
  local s = stats[session_id]
  if not s then
    local empty = new_stats()
    empty.breaks_per_request = 0
    empty.hit_ratio = 0
    return empty
  end
  local out = vim.deepcopy(s)
  out.breaks_per_request = s.requests > 0 and (s.breaks / s.requests) or 0
  out.hit_ratio = usage_util.hit_ratio({
    prompt_tokens = s.prompt_tokens,
    cached_tokens = s.cached_tokens,
  })
  return out
end

--- Forget everything recorded for a session.
--- @param session_id string
function M.reset(session_id)
  previous[session_id] = nil
  pending[session_id] = nil
  stats[session_id] = nil
end

--- Forget all sessions (used by tests).
function M.reset_all()
  previous = {}
  pending = {}
  stats = {}
end

return M


-- lua/chat/lark/identity.lua
-- Normalize ACL identity entries into open_id space.
--
-- Feishu has two disjoint user id systems:
--
--   open_id  (`ou_xxx`)  what message callbacks carry in `sender.id`
--   user_id  (`us_xxx`)  what the admin console shows; NEVER equals an open_id
--
-- An ACL entry is therefore only usable once it is expressed as an open_id.
-- Emails and phone numbers are accepted as a typing convenience (nobody wants
-- to copy a 30-char id from the console) and are resolved through
-- `contact/v3/users/batch_get_id`.
--
-- NOTE: `user_id_type=open_id` is mandatory. Without it the response carries
-- user_id-space values that look resolved but never match a sender id.
--
-- Resolution is a one-off cost at connect time (see ideas/lark-acl-bindings.md
-- 3.2.3): the resulting text -> open_id map is persisted and re-used until the
-- configured entries change.
local M = {}

local curl = require('chat.curl')
local job = require('job')
local log = require('chat.log')
local auth = require('chat.lark.auth')

local API_BASE = 'https://open.feishu.cn/open-apis'
-- Documented limit for one batch_get_id call.
local BATCH_SIZE = 50

--- Classify one configured ACL entry by its shape.
--- @param entry any
--- @return string 'open_id'|'email'|'phone'|'user_id'|'union_id'|'unknown'|'empty'
function M.classify(entry)
  if type(entry) ~= 'string' then
    return 'unknown'
  end
  if entry == '' then
    return 'empty'
  end
  if entry:match('^ou_') then
    return 'open_id'
  end
  -- Checked before the phone pattern: neither starts with a digit, but the
  -- order documents that `us_xxx` / `on_xxx` are recognised, not accidentally
  -- fed to the lookup API.
  if entry:match('^us_') then
    return 'user_id'
  end
  if entry:match('^on_') then
    return 'union_id'
  end
  if entry:find('@', 1, true) then
    return 'email'
  end
  if entry:match('^%+?%d') then
    return 'phone'
  end
  return 'unknown'
end

--- Email comparison key (case-insensitive).
--- @param value string
--- @return string
local function email_key(value)
  return 'email:' .. (value or ''):lower()
end

--- Phone comparison key.
--- The API may echo a differently formatted number than the one that was
--- sent (`+86 138...` vs `+86138...`), so compare on digits only.
--- @param value string
--- @return string
local function phone_key(value)
  return 'phone:' .. ((value or ''):gsub('[^%d]', ''))
end

--- @param kind string 'email'|'phone'
--- @param value string
--- @return string
local function key_of(kind, value)
  if kind == 'email' then
    return email_key(value)
  end
  return phone_key(value)
end

--- Split a list into chunks of at most `size` items.
--- @param list table[]
--- @param size integer
--- @return table[]
local function chunks_of(list, size)
  local out, current = {}, {}
  for _, item in ipairs(list) do
    table.insert(current, item)
    if #current == size then
      table.insert(out, current)
      current = {}
    end
  end
  if #current > 0 then
    table.insert(out, current)
  end
  return out
end

--- Keep the first occurrence of every string.
--- @param list string[]
--- @return string[]
local function dedupe(list)
  local seen, out = {}, {}
  for _, item in ipairs(list) do
    if not seen[item] then
      seen[item] = true
      table.insert(out, item)
    end
  end
  return out
end

--- POST one batch of emails / mobiles and hand back `data.user_list`.
---
--- The body travels over stdin so addresses never show up in argv (visible to
--- other processes through ps).
--- @param token string tenant_access_token
--- @param items table[] { kind = 'email'|'phone', value = string }
--- @param callback fun(user_list: table[]|nil, err: string|nil)
local function lookup_batch(token, items, callback)
  local emails, mobiles = {}, {}
  for _, item in ipairs(items) do
    if item.kind == 'email' then
      table.insert(emails, item.value)
    else
      table.insert(mobiles, item.value)
    end
  end

  local body = {}
  if #emails > 0 then
    body.emails = emails
  end
  if #mobiles > 0 then
    body.mobiles = mobiles
  end

  local cmd = curl.build_request({
    url = API_BASE .. '/contact/v3/users/batch_get_id?user_id_type=open_id',
    method = 'POST',
    headers = {
      'Authorization: Bearer ' .. token,
      'Content-Type: application/json',
    },
    stdin_body = true,
  })

  local stdout, stderr = {}, {}
  local done = false

  local function finish(user_list, err)
    if done then
      return
    end
    done = true
    callback(user_list, err)
  end

  local jobid = job.start(cmd, {
    on_stdout = function(_, lines)
      vim.list_extend(stdout, lines)
    end,
    on_stderr = function(_, lines)
      vim.list_extend(stderr, lines)
    end,
    on_exit = function(_, code, signal)
      if signal ~= 0 then
        finish(nil, 'identity lookup cancelled (signal: ' .. signal .. ')')
        return
      end

      local raw = table.concat(stdout, '\n')
      if code ~= 0 then
        local detail = table.concat(stderr, '\n')
        finish(
          nil,
          string.format(
            'identity lookup failed (curl exit %d): %s',
            code,
            detail ~= '' and detail or (raw ~= '' and raw or '(no output)')
          )
        )
        return
      end

      local ok, res = pcall(vim.json.decode, raw)
      if not ok or type(res) ~= 'table' then
        finish(nil, 'identity lookup returned invalid JSON: ' .. raw:sub(1, 200))
        return
      end

      if res.code and res.code ~= 0 then
        finish(
          nil,
          string.format(
            'Feishu API error %s: %s',
            tostring(res.code),
            res.msg or 'unknown'
          )
        )
        return
      end

      local data = res.data or {}
      finish(data.user_list or {}, nil)
    end,
  })

  if not jobid or jobid <= 0 then
    finish(nil, 'failed to start identity lookup request')
    return
  end

  job.send(jobid, vim.json.encode(body))
  job.send(jobid, nil)
end

--- Resolve a list of mixed ACL entries into open_id space.
---
--- The result is a map keyed by the *configured text*:
---
---   { ['nova@example.com'] = 'ou_...', failed = { ... }, error = '...' }
---
--- `failed` lists entries that could not be resolved (unknown shape, API
--- error, not found, permissions). Callers decide what that means: admins and
--- whitelist entries fail closed, blacklist entries fail open (see
--- ideas/lark-acl-bindings.md 3.2.7).
---
--- @param entries string[] Mixed open_id / email / phone entries
--- @param callback fun(result: table)
function M.resolve(entries, callback)
  callback = callback or function() end

  local resolved, failed, lookup, seen = {}, {}, {}, {}

  for _, entry in ipairs(entries or {}) do
    local kind = M.classify(entry)
    if kind == 'empty' then
      -- Empty strings are skipped silently: they are config noise, not a
      -- user who needs to be reported.
    elseif kind == 'open_id' then
      resolved[entry] = entry
    elseif kind == 'email' or kind == 'phone' then
      if not seen[entry] then
        seen[entry] = true
        table.insert(lookup, { kind = kind, value = entry })
      end
    else
      -- `us_xxx` / `on_xxx` / typos: reported, never dropped silently.
      log.error(
        '[Lark] Unsupported ACL identity entry (use open_id, email or mobile): '
          .. tostring(entry)
      )
      table.insert(failed, entry)
    end
  end

  local function report(err)
    resolved.failed = dedupe(failed)
    if err then
      resolved.error = err
    end
    callback(resolved)
  end

  -- open_id only: nothing to look up, zero API requests.
  if #lookup == 0 then
    report(nil)
    return
  end

  if not curl.is_available() then
    for _, item in ipairs(lookup) do
      table.insert(failed, item.value)
    end
    report('curl is not installed or not in PATH')
    return
  end

  local batches = chunks_of(lookup, BATCH_SIZE)

  local function run(index, token)
    if index > #batches then
      report(nil)
      return
    end

    local batch = batches[index]
    lookup_batch(token, batch, function(user_list, err)
      if err then
        -- One failed batch means the interface is unusable: fail every
        -- remaining entry instead of pretending they were rejected.
        for i = index, #batches do
          for _, item in ipairs(batches[i]) do
            table.insert(failed, item.value)
          end
        end
        report(err)
        return
      end

      local index_by_key = {}
      for i, user in ipairs(user_list) do
        local open_id = user.user_id
        if type(open_id) ~= 'string' or not open_id:match('^ou_') then
          -- Wrong id space (user_id_type missing / not applied): unusable.
          log.warn(
            '[Lark] batch_get_id returned a non open_id: ' .. tostring(open_id)
          )
        else
          local keyed = false
          if user.email then
            index_by_key[email_key(user.email)] = open_id
            keyed = true
          end
          if user.mobile then
            index_by_key[phone_key(user.mobile)] = open_id
            keyed = true
          end
          -- Some tenants omit the echoed field. The response keeps the
          -- request order, so an 1:1 reply can be mapped by position.
          if not keyed and #user_list == #batch and batch[i] then
            local item = batch[i]
            index_by_key[key_of(item.kind, item.value)] = open_id
          end
        end
      end

      for _, item in ipairs(batch) do
        local open_id = index_by_key[key_of(item.kind, item.value)]
        if open_id then
          resolved[item.value] = open_id
        else
          -- Not in the tenant / outside the app's availability scope.
          table.insert(failed, item.value)
        end
      end

      run(index + 1, token)
    end)
  end

  auth.ensure_token(function(token, token_err)
    if not token then
      for _, item in ipairs(lookup) do
        table.insert(failed, item.value)
      end
      report(token_err or 'failed to obtain tenant_access_token')
      return
    end
    run(1, token)
  end)
end

return M


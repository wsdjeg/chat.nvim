-- lua/chat/tools/mastodon.lua
-- Read-only Mastodon access via the public REST API (https://docs.joinmastodon.org/).
-- Three actions:
--   fetch    - get a single toot by URL (or id+instance), optionally with the
--              whole thread (ancestors + replies)
--   search   - /api/v2/search for statuses / accounts / hashtags (requires an
--              access token on most instances)
--   timeline - public timeline (local=true restricts to local toots) or a
--              hashtag timeline via timeline="tag:<hashtag>"
-- GET only: this tool never posts, boosts or favourites anything.

local M = {}

local curl = require('chat.curl')
local config = require('chat.config')

local DEFAULT_LIMIT = 20
local MAX_LIMIT = 40
local DEFAULT_TIMEOUT = 30

--- Percent-encode a string for use in a URL query or path segment.
---@param str string|number
---@return string
local function url_encode(str)
  if type(str) ~= 'string' then
    str = tostring(str)
  end
  return (str:gsub('[^%w%-._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

--- Normalize an instance into an origin URL ("https://host").
--- Accepts "mastodon.social", "https://mastodon.social", "https://host/path"...
---@param inst string|nil
---@return string|nil origin
local function normalize_instance(inst)
  if type(inst) ~= 'string' then
    return nil
  end
  inst = inst:gsub('^%s+', ''):gsub('%s+$', '')
  if inst == '' then
    return nil
  end
  if inst:find('^https?://') then
    return inst:match('^(https?://[^/]+)')
  end
  return 'https://' .. inst:match('^([^/]+)')
end

--- Parse a toot URL into (instance_origin, status_id).
--- Supported shapes:
---   https://<instance>/@<user>/<id>
---   https://<instance>/@<user>@<domain>/<id>   (remote user shown locally)
--- Trailing slashes / query strings are ignored.
--- Exported as _parse_toot_url for tests.
---@param url string
---@return string|nil instance
---@return string|nil id
function M._parse_toot_url(url)
  if type(url) ~= 'string' then
    return nil
  end
  local instance, id = url:match('^(https?://[^/]+)/@[%w%.%-_@]+/(%d+)')
  if not instance or not id then
    return nil
  end
  return instance, id
end

--- Convert Mastodon HTML content (status content, bio, CW text) to plain text.
--- Exported as _strip_html for tests.
---@param html string|nil
---@return string
function M._strip_html(html)
  if type(html) ~= 'string' or html == '' then
    return ''
  end
  local text = html
  text = text:gsub('<br%s*/?>', '\n')
  text = text:gsub('</%s*p%s*>%s*<%s*p[^>]*>', '\n\n')
  text = text:gsub('<[^>]*>', '')
  -- decode common HTML entities (&amp; last so "&amp;lt;" stays two-step safe)
  text = text:gsub('&lt;', '<')
  text = text:gsub('&gt;', '>')
  text = text:gsub('&quot;', '"')
  text = text:gsub('&#39;', "'")
  text = text:gsub('&apos;', "'")
  text = text:gsub('&nbsp;', ' ')
  text = text:gsub('&amp;', '&')
  return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Normalize the limit parameter: default DEFAULT_LIMIT, clamp to MAX_LIMIT.
---@param limit any
---@return integer|nil limit
---@return string|nil err
local function normalize_limit(limit)
  if limit == nil or limit == '' then
    return DEFAULT_LIMIT, nil
  end
  local n = tonumber(limit)
  if not n or n < 1 then
    return nil, string.format('limit must be a positive integer (1-%d).', MAX_LIMIT)
  end
  if n > MAX_LIMIT then
    n = MAX_LIMIT
  end
  return math.floor(n), nil
end

--- Perform a synchronous GET against a Mastodon API endpoint, decode JSON.
--- Mastodon returns JSON error bodies ({"error":"..."}) with 4xx status codes;
--- curl runs without --fail so those surface here as decoded tables.
---@param url string
---@param opts table { headers = string[]|nil, timeout = integer }
---@return table|nil data
---@return string|nil err
local function api_get(url, opts)
  opts = opts or {}
  local timeout = opts.timeout or DEFAULT_TIMEOUT

  local cmd = curl.build_request({
    url = url,
    method = 'GET',
    headers = opts.headers,
    follow_redirects = true,
    compressed = true,
    max_time = timeout,
    user_agent = 'chat.nvim (mastodon tool)',
  })

  local result, exit_code
  if vim.system then
    local job = vim.system(cmd, { text = true, timeout = timeout * 1000 })
    local r = job:wait()
    result = r.stdout or ''
    if r.code ~= 0 and r.stderr and r.stderr ~= '' then
      result = result ~= '' and (result .. '\n\n' .. r.stderr) or r.stderr
    end
    exit_code = r.code
  else
    result = vim.fn.system(cmd)
    exit_code = vim.v.shell_error
  end

  if exit_code ~= 0 then
    local hint = curl.get_error_message(exit_code)
    return nil, string.format(
      'Mastodon request failed (curl exit code %d).%s\nURL: %s',
      exit_code,
      hint and (' ' .. hint) or '',
      url
    )
  end

  if result == '' then
    return nil, 'Mastodon returned an empty response.\nURL: ' .. url
  end

  local ok, data = pcall(vim.json.decode, result)
  if not ok or type(data) ~= 'table' then
    return nil, 'Failed to parse Mastodon response as JSON.\nURL: ' .. url
  end

  -- API-level error (401/404/... arrive as JSON with an "error" key)
  if type(data.error) == 'string' then
    local msg =
      string.format('Mastodon API error: %s\nURL: %s', data.error, url)
    local lower = data.error:lower()
    if
      lower:find('token')
      or lower:find('authenticat')
      or lower:find('credential')
    then
      msg = msg
        .. '\nHint: this endpoint requires an access token. Set mastodon.access_token in your chat.nvim config (or pass access_token).'
    end
    return nil, msg
  end

  return data, nil
end

--- Append a formatted status block to `lines`.
--- Boosts (reblog) are shown as "X boosted @Y:" followed by the inner toot.
---@param lines string[]
---@param status table Mastodon Status entity
---@param label string|nil optional block heading, e.g. "Reply 2/5"
local function append_status(lines, status, label)
  local account = status.account or {}
  local author = '@' .. (account.acct or account.username or 'unknown')
  if account.display_name and account.display_name ~= '' then
    author = author .. ' (' .. account.display_name .. ')'
  end

  if status.reblog then
    if label then
      table.insert(lines, string.format('--- %s ---', label))
    end
    local rb_account = status.reblog.account or {}
    table.insert(
      lines,
      string.format('%s boosted @%s:', author, rb_account.acct or 'unknown')
    )
    table.insert(lines, '')
    append_status(lines, status.reblog, nil)
    return
  end

  if label then
    table.insert(lines, string.format('--- %s ---', label))
  end
  table.insert(lines, author .. ' · ' .. (status.created_at or 'unknown date'))

  if status.spoiler_text and status.spoiler_text ~= '' then
    table.insert(lines, '[CW: ' .. M._strip_html(status.spoiler_text) .. ']')
  end

  local text = M._strip_html(status.content or '')
  if text == '' then
    text = '(no text content)'
  end
  table.insert(lines, text)

  local media = {}
  for _, m in ipairs(status.media_attachments or {}) do
    local desc = m.type or 'unknown'
    if m.description and m.description ~= '' then
      desc = desc .. ': ' .. m.description
    end
    table.insert(media, desc .. ' ' .. (m.url or m.preview_url or '?'))
  end
  if #media > 0 then
    table.insert(lines, 'Media: ' .. table.concat(media, ' | '))
  end

  table.insert(
    lines,
    string.format(
      'replies=%d boosts=%d favorites=%d',
      status.replies_count or 0,
      status.reblogs_count or 0,
      status.favourites_count or 0
    )
  )
  if status.url then
    table.insert(lines, 'URL: ' .. status.url)
  end
  table.insert(lines, '')
end

--- Resolve instance origin + auth headers shared by all actions.
---@param action ChatToolsMastodonAction
---@param mcfg table config.config.mastodon
---@return string|nil instance
---@return string|nil err
---@return string[]|nil headers
local function resolve_instance_and_headers(action, mcfg)
  local instance = normalize_instance(action.instance or mcfg.instance)
  if not instance then
    return nil, string.format(
      'invalid instance "%s". Set mastodon.instance in config or pass a valid instance URL.',
      tostring(action.instance or mcfg.instance)
    ), nil
  end
  local token = action.access_token or mcfg.access_token or ''
  local headers = token ~= '' and { 'Authorization: Bearer ' .. token } or nil
  return instance, nil, headers
end

---@class ChatToolsMastodonAction
---@field action string One of "fetch", "search", "timeline"
---@field url? string Toot URL, e.g. https://mastodon.social/@user/123 (fetch)
---@field id? string|number Numeric status ID; requires instance (fetch)
---@field context? boolean Also fetch thread ancestors and replies (fetch)
---@field query? string Search query (search)
---@field type? string "statuses", "accounts" or "hashtags" (search)
---@field timeline? string "public" or "tag:<hashtag>" (timeline)
---@field local? boolean Only local toots (timeline)
---@field instance? string Instance override, e.g. "https://fosstodon.org"
---@field limit? integer Max results for search/timeline (default 20, max 40)
---@field access_token? string Access token override
---@field timeout? integer Timeout in seconds (default 30)

--- fetch action: single toot (or whole thread with context=true).
---@param action ChatToolsMastodonAction
---@param mcfg table
---@param timeout number
---@return table
function M._fetch(action, mcfg, timeout)
  local instance, id

  if action.url ~= nil and action.url ~= '' then
    if type(action.url) ~= 'string' then
      return { error = 'url must be a string.' }
    end
    instance, id = M._parse_toot_url(action.url)
    if not instance then
      return {
        error = 'could not parse toot URL. Expected format: https://<instance>/@<user>/<status_id>',
      }
    end
  elseif action.id ~= nil and action.id ~= '' then
    id = tostring(action.id)
    if not id:match('^%d+$') then
      return { error = 'id must be a numeric status ID.' }
    end
    local err
    instance, err = resolve_instance_and_headers(action, mcfg)
    if err then
      return { error = err }
    end
  else
    return {
      error = 'fetch requires url (toot URL) or id (+ instance).',
    }
  end

  if not curl.is_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  local headers = select(3, resolve_instance_and_headers(action, mcfg))

  local status, err = api_get(
    instance .. '/api/v1/statuses/' .. id,
    { headers = headers, timeout = timeout }
  )
  if err then
    return { error = err }
  end

  local lines = {}
  append_status(lines, status, 'Toot')

  if action.context then
    local ctx_data, cerr = api_get(
      instance .. '/api/v1/statuses/' .. id .. '/context',
      { headers = headers, timeout = timeout }
    )
    if cerr then
      table.insert(lines, '(thread context unavailable: ' .. cerr .. ')')
    else
      local ancestors = ctx_data.ancestors or {}
      local descendants = ctx_data.descendants or {}
      if #ancestors > 0 then
        table.insert(
          lines,
          string.format('=== Thread ancestors (%d) ===', #ancestors)
        )
        for i, s in ipairs(ancestors) do
          append_status(
            lines,
            s,
            string.format('Ancestor %d/%d', i, #ancestors)
          )
        end
      end
      if #descendants > 0 then
        table.insert(
          lines,
          string.format('=== Thread replies (%d) ===', #descendants)
        )
        for i, s in ipairs(descendants) do
          append_status(
            lines,
            s,
            string.format('Reply %d/%d', i, #descendants)
          )
        end
      end
      if #ancestors == 0 and #descendants == 0 then
        table.insert(lines, '(no ancestors and no replies)')
      end
    end
  end

  return { content = table.concat(lines, '\n') }
end

--- search action: /api/v2/search for statuses / accounts / hashtags.
---@param action ChatToolsMastodonAction
---@param mcfg table
---@param timeout number
---@return table
function M._search(action, mcfg, timeout)
  local q = action.query
  if type(q) ~= 'string' or q == '' then
    return { error = 'search requires a non-empty query.' }
  end

  local stype = action.type
  if stype == nil or stype == '' then
    stype = nil
  elseif
    stype ~= 'statuses'
    and stype ~= 'accounts'
    and stype ~= 'hashtags'
  then
    return {
      error = 'type must be one of: "statuses", "accounts", "hashtags".',
    }
  end

  local limit, lerr = normalize_limit(action.limit)
  if lerr then
    return { error = lerr }
  end

  local instance, err, headers =
    resolve_instance_and_headers(action, mcfg)
  if err then
    return { error = err }
  end

  if not curl.is_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  local url =
    string.format('%s/api/v2/search?q=%s&limit=%d', instance, url_encode(q), limit)
  if stype then
    url = url .. '&type=' .. stype
  end

  local data, aerr = api_get(url, { headers = headers, timeout = timeout })
  if aerr then
    return { error = aerr }
  end

  local statuses = data.statuses or {}
  local accounts = data.accounts or {}
  local hashtags = data.hashtags or {}

  local lines = {
    string.format('Mastodon search results for "%s" on %s:', q, instance),
    '',
  }

  if stype == nil or stype == 'statuses' then
    if #statuses > 0 then
      table.insert(lines, string.format('== Statuses (%d) ==', #statuses))
      for i, s in ipairs(statuses) do
        append_status(lines, s, string.format('Status %d/%d', i, #statuses))
      end
    end
  end

  if stype == nil or stype == 'accounts' then
    if #accounts > 0 then
      table.insert(lines, string.format('== Accounts (%d) ==', #accounts))
      for i, a in ipairs(accounts) do
        table.insert(
          lines,
          string.format(
            '%d. @%s (%s)',
            i,
            a.acct or '?',
            a.display_name or 'no display name'
          )
        )
        table.insert(
          lines,
          string.format(
            '   followers=%d following=%d posts=%d',
            a.followers_count or 0,
            a.following_count or 0,
            a.statuses_count or 0
          )
        )
        local note = M._strip_html(a.note or '')
        if note ~= '' then
          note = note:gsub('[\r\n]+', ' ')
          table.insert(lines, '   bio: ' .. note)
        end
        table.insert(lines, string.format('   URL: %s', a.url or '?'))
        table.insert(lines, '')
      end
    end
  end

  if stype == nil or stype == 'hashtags' then
    if #hashtags > 0 then
      table.insert(lines, string.format('== Hashtags (%d) ==', #hashtags))
      for i, h in ipairs(hashtags) do
        local uses = 0
        if
          type(h.history) == 'table'
          and h.history[1]
          and h.history[1].uses
        then
          uses = tonumber(h.history[1].uses) or 0
        end
        table.insert(
          lines,
          string.format(
            '%d. #%s (uses today: %d) %s',
            i,
            h.name or '?',
            uses,
            h.url or ''
          )
        )
      end
      table.insert(lines, '')
    end
  end

  if #statuses == 0 and #accounts == 0 and #hashtags == 0 then
    table.insert(lines, 'No results found.')
  end

  return { content = table.concat(lines, '\n') }
end

--- timeline action: public timeline or hashtag timeline.
---@param action ChatToolsMastodonAction
---@param mcfg table
---@param timeout number
---@return table
function M._timeline(action, mcfg, timeout)
  local tl = action.timeline
  if type(tl) ~= 'string' or tl == '' then
    return { error = 'timeline is required: "public" or "tag:<hashtag>".' }
  end

  local limit, lerr = normalize_limit(action.limit)
  if lerr then
    return { error = lerr }
  end

  local instance, err, headers =
    resolve_instance_and_headers(action, mcfg)
  if err then
    return { error = err }
  end

  local url
  if tl == 'public' then
    url = instance .. '/api/v1/timelines/public?limit=' .. limit
  else
    local tag = tl:match('^tag:%s*#?(.-)%s*$')
    if not tag or tag == '' then
      return {
        error = string.format(
          'invalid timeline "%s". Use "public" or "tag:<hashtag>".',
          tl
        ),
      }
    end
    url = string.format(
      '%s/api/v1/timelines/tag/%s?limit=%d',
      instance,
      url_encode(tag),
      limit
    )
  end
  if action['local'] then
    url = url .. '&local=true'
  end

  if not curl.is_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  local data, aerr = api_get(url, { headers = headers, timeout = timeout })
  if aerr then
    return { error = aerr }
  end

  local lines = {
    string.format('Mastodon %s timeline (%s, %d toots):', tl, instance, #data),
    '',
  }
  for i, s in ipairs(data) do
    append_status(lines, s, string.format('%d/%d', i, #data))
  end
  if #data == 0 then
    table.insert(
      lines,
      'Timeline is empty (or the instance restricts unauthenticated access).'
    )
  end

  return { content = table.concat(lines, '\n') }
end

--- Main entry point.
---@param action ChatToolsMastodonAction
---@param ctx ChatToolContext
---@return table
function M.mastodon(action, _)
  action = action or {}

  local kind = action.action
  if type(kind) ~= 'string' or kind == '' then
    return {
      error = 'action is required and must be one of: "fetch", "search", "timeline".',
    }
  end

  local timeout = action.timeout or DEFAULT_TIMEOUT
  if type(timeout) ~= 'number' or timeout < 1 or timeout > 300 then
    return { error = 'timeout must be between 1 and 300 seconds.' }
  end

  local mcfg = config.config.mastodon or {}

  if kind == 'fetch' then
    return M._fetch(action, mcfg, timeout)
  elseif kind == 'search' then
    return M._search(action, mcfg, timeout)
  elseif kind == 'timeline' then
    return M._timeline(action, mcfg, timeout)
  end

  return {
    error = string.format(
      'unknown action "%s". Use "fetch", "search" or "timeline".',
      kind
    ),
  }
end

--- One-line introduction for the find_tool catalog.
function M.introduction()
  return 'Read-only Mastodon access: fetch toots/threads, search, public and hashtag timelines'
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'mastodon',
      description = [[
Read-only Mastodon access: fetch toots and threads, search, read public and hashtag timelines. Never posts or interacts - GET requests only.

Three actions:

1. fetch - get a single toot by its URL, or the whole thread with context=true
2. search - search statuses, accounts or hashtags (requires an access token on most instances; set mastodon.access_token in config)
3. timeline - read the public timeline (local=true for local toots only) or a hashtag timeline via timeline="tag:<hashtag>"

The default instance is mastodon.social; override per call with instance="https://fosstodon.org" or set mastodon.instance in config.

EXAMPLES:

1. Fetch one toot:
   @mastodon action="fetch" url="https://mastodon.social/@gargron/109307870061423362"

2. Fetch a whole thread (ancestors + replies):
   @mastodon action="fetch" url="https://mastodon.social/@user/123456" context=true

3. Fetch by id on a specific instance:
   @mastodon action="fetch" id="123456" instance="https://fosstodon.org"

4. Search statuses (needs mastodon.access_token configured):
   @mastodon action="search" query="neovim" type="statuses"

5. Search accounts:
   @mastodon action="search" query="gargron" type="accounts"

6. Public timeline of another instance:
   @mastodon action="timeline" timeline="public" instance="https://fosstodon.org"

7. Local-only public timeline:
   @mastodon action="timeline" timeline="public" local=true

8. Hashtag timeline:
   @mastodon action="timeline" timeline="tag:neovim" limit=40
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'One of: "fetch" (single toot/thread), "search" (statuses/accounts/hashtags), "timeline" (public or tag timeline)',
            enum = { 'fetch', 'search', 'timeline' },
          },
          url = {
            type = 'string',
            description = 'Toot URL (fetch): https://<instance>/@<user>/<status_id>. The instance from the URL is used automatically.',
          },
          id = {
            type = 'string',
            description = 'Numeric status ID (fetch alternative to url). Requires instance.',
          },
          context = {
            type = 'boolean',
            description = 'Fetch the whole thread: ancestors and replies (fetch).',
          },
          query = {
            type = 'string',
            description = 'Search query (search).',
          },
          type = {
            type = 'string',
            description = 'What to search for (search): statuses, accounts or hashtags. Omit to search all.',
            enum = { 'statuses', 'accounts', 'hashtags' },
          },
          timeline = {
            type = 'string',
            description = 'Timeline to read (timeline): "public" or "tag:<hashtag>" e.g. "tag:neovim".',
          },
          ['local'] = {
            type = 'boolean',
            description = 'Restrict timeline to local (same-instance) toots only (timeline).',
          },
          instance = {
            type = 'string',
            description = 'Instance override, e.g. "https://fosstodon.org" or "fosstodon.org". Default: mastodon.social (config mastodon.instance).',
          },
          limit = {
            type = 'integer',
            description = 'Maximum number of results for search/timeline (default: 20, max: 40).',
            minimum = 1,
            maximum = 40,
          },
          access_token = {
            type = 'string',
            description = 'Access token override for authenticated endpoints (search). Default: config mastodon.access_token.',
          },
          timeout = {
            type = 'integer',
            description = 'Timeout in seconds (default: 30, minimum: 1, maximum: 300).',
            minimum = 1,
            maximum = 300,
          },
        },
        required = { 'action' },
      },
    },
  }
end

function M.info(action, _)
  local ok, arguments = pcall(vim.json.decode, action)
  if not ok or type(arguments) ~= 'table' then
    return 'mastodon'
  end

  local parts = { 'mastodon ' .. (tostring(arguments.action) or '?') }

  if arguments.action == 'fetch' then
    if arguments.url and arguments.url ~= '' then
      table.insert(parts, tostring(arguments.url))
    elseif arguments.id ~= nil and arguments.id ~= '' then
      table.insert(parts, 'id=' .. tostring(arguments.id))
    end
    if arguments.context then
      table.insert(parts, 'context=true')
    end
  elseif arguments.action == 'search' then
    if arguments.query and arguments.query ~= '' then
      table.insert(parts, string.format('"%s"', arguments.query))
    end
    if arguments.type then
      table.insert(parts, string.format('type=%s', arguments.type))
    end
  elseif arguments.action == 'timeline' then
    if arguments.timeline and arguments.timeline ~= '' then
      table.insert(parts, tostring(arguments.timeline))
    end
    if arguments['local'] then
      table.insert(parts, 'local=true')
    end
  end

  if arguments.instance then
    table.insert(parts, string.format('instance=%s', arguments.instance))
  end
  if arguments.limit then
    table.insert(parts, string.format('limit=%d', tonumber(arguments.limit) or 0))
  end

  return table.concat(parts, ' ')
end

return M


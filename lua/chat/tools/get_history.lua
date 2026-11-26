-- lua/chat/tools/get_history.lua
-- Tool for LLM to retrieve and search conversation history

local M = {}

local log = require('chat.log')
local util = require('chat.util')

-- ── Size budget ──────────────────────────────────────────────────────
-- History messages carry raw content, and a single tool result (a
-- read_file, a fetch_web, a git diff) can be hundreds of KB. Returning 50
-- of them would push the very request that carries the tool result over
-- the model's context window, so the result is capped by BYTES, not just
-- by message count.
local DEFAULT_MAX_BYTES = 32 * 1024 -- budget used when max_bytes is omitted
local MAX_MAX_BYTES = 200 * 1024 -- hard ceiling for an explicit max_bytes
local MIN_MAX_BYTES = 2048 -- floor: a smaller body cannot hold the envelope
-- Content prefix below this size is not worth returning: the truncation
-- note alone costs more bytes, so such a message is dropped instead of
-- cut (it is still reported through next_offset/note).
local MIN_ENTRY_BYTES = 160
-- Metadata that appears only after layout (truncated, next_offset, note,
-- bytes) plus JSON punctuation, reserved before content is laid out.
local ENVELOPE_HEADROOM = 512

--- Normalize the max_bytes parameter.
--- Non-number values and values <= 0 fall back to the default; the rest
--- is clamped into [MIN_MAX_BYTES, MAX_MAX_BYTES] so every accepted value
--- can actually hold a valid result body.
---@param v any
---@return integer
local function normalize_max_bytes(v)
  if type(v) ~= 'number' or v <= 0 then
    return DEFAULT_MAX_BYTES
  end
  if v < MIN_MAX_BYTES then
    return MIN_MAX_BYTES
  end
  if v > MAX_MAX_BYTES then
    return MAX_MAX_BYTES
  end
  return math.floor(v)
end

--- Encode a response and fill `bytes` with its encoded length.
--- `bytes` is part of the payload, so its digit count feeds back into the
--- total: re-encode until the reported value matches (converges in one or
--- two passes, the loop is bounded anyway).
---@param response table
---@return string content
local function encode_response(response)
  response.bytes = 0
  local content = vim.json.encode(response)
  for _ = 1, 3 do
    if response.bytes == #content then
      break
    end
    response.bytes = #content
    content = vim.json.encode(response)
  end
  return content
end

--- Lay out history entries so the encoded response stays within max_bytes.
---
--- Each entry is measured as JSON (escaping included) plus one byte for the
--- separating comma, so the estimate stays an upper bound of what the model
--- receives. The first entry that does not fit whole is cut at a UTF-8
--- boundary and returned as a head plus a truncation note; everything after
--- it is dropped.
---
---@param entries table[] Working-set slices, first one at working position `offset`
---@param offset integer 0-based working-set position of entries[1]
---@param envelope table Response skeleton with metadata already filled in
---@param max_bytes integer Budget for the whole encoded response
---@return table[] kept Chosen entries, possibly with content cut
---@return table layout { truncated, next_offset, cut_index, dropped_whole }
local function fit_entries(entries, offset, envelope, max_bytes)
  local budget = max_bytes - #vim.json.encode(envelope) - ENVELOPE_HEADROOM
  local used = 0
  local kept = {}
  local layout = {
    truncated = false,
    next_offset = nil,
    cut_index = nil,
    dropped_whole = nil,
  }

  for i, entry in ipairs(entries) do
    local wpos = offset + i - 1
    local size = #vim.json.encode(entry) + 1 -- + separating comma
    local remaining = budget - used

    if size <= remaining then
      table.insert(kept, entry)
      used = used + size
    else
      layout.truncated = true
      local content = entry.content
      local overhead = size - (type(content) == 'string' and #content or 0)

      if
        type(content) == 'string'
        and remaining - overhead > MIN_ENTRY_BYTES
      then
        -- Return the head of the content so the model can tell what the
        -- message was about, and flag it so a follow-up call with a larger
        -- max_bytes can read the rest.
        local original_bytes = #content
        local note = string.format(
          '\n\n[Content truncated: message is %d bytes, only the head fits '
            .. 'the %d-byte result budget. Re-read it with a larger max_bytes.]',
          original_bytes,
          max_bytes
        )
        local cut = util.utf8_truncate(
          content,
          remaining - overhead - #note - 8
        )
        while cut ~= '' do
          local cut_entry = {
            index = entry.index,
            role = entry.role,
            content = cut .. note,
            created = entry.created,
            content_truncated = true,
            original_bytes = original_bytes,
          }
          local cut_size = #vim.json.encode(cut_entry) + 1
          if cut_size <= remaining then
            table.insert(kept, cut_entry)
            used = used + cut_size
            layout.cut_index = entry.index
            break
          end
          -- JSON escaping (quotes, newlines) inflates the encoded size:
          -- shrink the cut by the overrun and measure again.
          cut = util.utf8_truncate(cut, #cut - (cut_size - remaining) - 8)
        end
        if layout.cut_index then
          -- Progress is guaranteed: the cut message's head was returned, so
          -- the next call continues after it.
          layout.next_offset = wpos + 1
        end
      end

      if not layout.next_offset then
        -- Nothing of this message was returned. Point back at it: only a
        -- larger max_bytes can make it readable.
        layout.next_offset = wpos
        layout.dropped_whole = entry.index
      end
      break
    end
  end

  return kept, layout
end

--- Build the truncation note for a layout result.
---@param layout table Result of fit_entries()
---@param max_bytes integer
---@return string
local function truncation_note(layout, max_bytes)
  if layout.cut_index ~= nil then
    return string.format(
      'Result capped at %d bytes. Message index %d was cut (see '
        .. 'content_truncated/original_bytes); re-read it with a larger '
        .. 'max_bytes, then continue from offset=%d.',
      max_bytes,
      layout.cut_index,
      layout.next_offset
    )
  end
  if layout.dropped_whole ~= nil then
    return string.format(
      'Result capped at %d bytes. Message index %d does not fit; increase '
        .. 'max_bytes (ceiling %d) or narrow the range.',
      max_bytes,
      layout.dropped_whole,
      MAX_MAX_BYTES
    )
  end
  return string.format(
    'Result capped at %d bytes. Continue with offset=%d.',
    max_bytes,
    layout.next_offset
  )
end

---@class ChatToolsGetHistoryAction
---@field offset? integer Starting index (0 = oldest message, default 0)
---@field limit? integer Number of messages to retrieve (default 20, max 50)
---@field search? string Keyword to filter messages (case-insensitive)
---@field max_bytes? integer Byte budget for the returned JSON

--- Get tool schema for LLM
--- @return table: Tool schema
function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'get_history',
      description = [[
Get conversation history messages from the current session.

Use this tool when you need to reference earlier messages that are not in the current context window.

Returns the requested messages with their role, content, and timestamp.

When `search` is provided, only messages containing the keyword (case-insensitive) are returned. Offset and limit apply to the filtered results.

The result is capped by bytes (max_bytes, default 32768, allowed 2048-204800), because a single tool result in the history can be very large. When the budget is exhausted the response reports `truncated: true`, `next_offset` (the position to continue from) and a `note`; a partially returned message is marked `content_truncated: true` with its `original_bytes`.

Examples:
- get_history(offset=0, limit=20) — Get the first 20 messages (oldest)
- get_history(offset=20, limit=20) — Get messages 21-40
- get_history(offset=0, limit=50) — Get first 50 messages (max)
- get_history(search="error") — Search for messages containing "error"
- get_history(search="config", offset=0, limit=10) — Search "config", first 10 matches
- get_history(offset=12, max_bytes=8000) — Continue from next_offset with a smaller budget
]],
      parameters = {
        type = 'object',
        properties = {
          offset = {
            type = 'integer',
            description = 'Starting index (0 = oldest message, default 0)',
          },
          limit = {
            type = 'integer',
            description = 'Number of messages to retrieve (default 20, max 50)',
          },
          search = {
            type = 'string',
            description = 'Keyword to filter messages (case-insensitive). When provided, only matching messages are returned.',
          },
          max_bytes = {
            type = 'integer',
            description = 'Byte budget for the returned JSON (default 32768, allowed 2048-204800). Values <= 0 fall back to the default. Check `truncated`/`next_offset` when the budget is exhausted.',
          },
        },
        required = {},
      },
    },
  }
end

--- Handle tool call
---@param action ChatToolsGetHistoryAction
---@param ctx ChatToolContext
---@return table: Result { content } or { error }
function M.get_history(action, ctx)
  local sessions = require('chat.sessions')

  if not ctx.session or not sessions.exists(ctx.session) then
    return { error = 'No active session' }
  end

  local messages = sessions.get_messages(ctx.session)
  if not messages or #messages == 0 then
    return { content = 'No messages in session history.' }
  end

  local offset = math.max(math.floor(action.offset or 0), 0)
  local limit = math.floor(action.limit or 20)
  if limit < 1 then
    limit = 1
  end
  limit = math.min(limit, 50)
  local max_bytes = normalize_max_bytes(action.max_bytes)
  local search = action.search

  -- Build the working set: all messages or filtered by search keyword
  local working_set = {}
  if search and search ~= '' then
    local search_lower = string.lower(search)
    for i, msg in ipairs(messages) do
      if
        msg.content
        and type(msg.content) == 'string'
        and string.find(string.lower(msg.content), search_lower, 1, true)
      then
        table.insert(working_set, {
          index = i - 1, -- 0-indexed for LLM
          role = msg.role,
          content = msg.content,
          created = msg.created,
        })
      end
    end
  else
    for i, msg in ipairs(messages) do
      table.insert(working_set, {
        index = i - 1, -- 0-indexed for LLM
        role = msg.role,
        content = msg.content,
        created = msg.created,
      })
    end
  end

  -- Check offset against working set size
  if offset >= #working_set then
    if search and search ~= '' then
      return {
        content = string.format(
          'Offset %d is beyond matched message count (%d). Search keyword: "%s"',
          offset,
          #working_set,
          search
        ),
      }
    else
      return {
        content = string.format(
          'Offset %d is beyond total message count (%d).',
          offset,
          #working_set
        ),
      }
    end
  end

  -- Slice the working set with offset and limit
  local picked = {}
  for pos = offset + 1, math.min(offset + limit, #working_set) do
    table.insert(picked, working_set[pos])
  end

  -- Response skeleton: metadata is part of the payload, so it shares the
  -- byte budget with the messages.
  local response = {
    total = #messages,
    offset = offset,
    limit = limit,
    max_bytes = max_bytes,
    returned = 0,
    messages = {},
  }
  if search and search ~= '' then
    response.search = search
    response.total_matched = #working_set
  end

  local kept, layout = fit_entries(picked, offset, response, max_bytes)

  response.messages = kept
  response.returned = #kept
  if layout.truncated then
    response.truncated = true
    response.next_offset = layout.next_offset
    response.note = truncation_note(layout, max_bytes)
  end

  local content = encode_response(response)

  -- Hard guarantee: never return more than the budget. Only reachable when
  -- the response metadata alone (e.g. an absurdly long search keyword) eats
  -- the whole budget; fall back to a payload without the messages first,
  -- then to plain text.
  if #content > max_bytes then
    response.messages = {}
    response.returned = 0
    response.truncated = true
    response.next_offset = offset
    response.note = nil
    content = encode_response(response)
    if #content > max_bytes then
      content = string.format(
        'get_history metadata does not fit max_bytes=%d. '
          .. 'Increase max_bytes (ceiling %d).',
        max_bytes,
        MAX_MAX_BYTES
      )
    end
  end

  log.debug(
    string.format(
      '[get_history] Retrieved %d messages (offset=%d, total=%d, bytes=%d%s%s)',
      #kept,
      offset,
      #messages,
      #content,
      search
          and search ~= ''
          and (', search="' .. search .. '", matched=' .. #working_set)
        or '',
      layout.truncated and ' [truncated]' or ''
    )
  )

  return { content = content }
end

--- Format tool info for display
---@param action string
---@return string: Formatted info
function M.info(action, _)
  local ok, arguments = pcall(vim.json.decode, action)
  if not ok then
    return 'get_history'
  end

  local offset = arguments.offset or 0
  local limit = arguments.limit or 20
  local search = arguments.search
  local max_bytes = arguments.max_bytes

  local parts = {}
  if search and search ~= '' then
    table.insert(parts, string.format('search="%s"', search))
  end
  table.insert(parts, string.format('offset=%d', offset))
  table.insert(parts, string.format('limit=%d', limit))
  if type(max_bytes) == 'number' then
    table.insert(parts, string.format('max_bytes=%d', max_bytes))
  end
  return string.format('get_history(%s)', table.concat(parts, ', '))
end

return M


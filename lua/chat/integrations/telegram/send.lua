-- lua/chat/integrations/telegram/send.lua
-- Outbound side: chunked, queued delivery to one chat.
--
-- Queued chunks carry their own destination: two chats replying at the same
-- time must not leak chunks into each other.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local chunker = require('chat.utils.chunker')
local util = require('chat.integrations.telegram.util')

local json = vim.json

local M = {}

--- @param ctx table shared instance context
--- @return table send API
function M.new(ctx)
  local state = ctx.state

  -- Per-instance queue and in-flight job: a reload starts with an idle sender.
  local message_queue = {}
  local send_message_jobid = -1

  -- Whether a dispatch already owns the queue. Set from the moment the head is
  -- taken until its job exits, which is what keeps two chats from interleaving
  -- their chunks in one conversation.
  local dispatch_busy = false

  -- Forward declaration: start_send and dispatch_message re-enter each other.
  local dispatch_message

  --- Drop the whole queue after a failure that affects every chunk.
  ---
    --- A missing bot token is a global condition: it fails for each queued
  --- chunk identically, so serving them one at a time would log one error per
  --- chunk for a single outage.
  --- @param reason string
  --- @param dropped integer chunks dropped, the one already taken included
  local function abandon_queue(reason, dropped)
    message_queue = {}
    send_message_jobid = -1
    dispatch_busy = false
    log.error(
      '[Telegram] Skip send: '
        .. reason
        .. ' ('
        .. tostring(dropped)
        .. ' chunk(s) dropped)'
    )
  end

  --- Body of one `sendMessage` call.
  ---
  --- `parse_mode = 'Markdown'` is legacy Telegram Markdown: unbalanced `*` or
  --- `_` in a model reply make the API reject the whole message with 400
  --- "can't parse entities". `MarkdownV2` is stricter still (every `.`, `-`,
  --- `(` must be escaped), which is worse for LLM output. The classic mode is
  --- kept (it is what the integration always sent), and a rejected message is
  --- retried once as plain text so the reply is not silently lost.
  --- @param chat_id string
  --- @param content string
  --- @param plain boolean drop parse_mode entirely
  --- @return string
  local function encode_body(chat_id, content, plain)
    local body = {
      chat_id = chat_id,
      text = content,
    }
    if not plain then
      body.parse_mode = 'Markdown'
    end
    return json.encode(body)
  end

  --- Start the request for one queued item.
  --- @param item table { content, chat_id }
  --- @param plain boolean retry without parse_mode
  local function start_send(item, plain)
    local bot_token = util.bot_token()
    if not bot_token then
      abandon_queue('bot_token not configured', 1 + #message_queue)
      return
    end

    local body = encode_body(item.chat_id, item.content, plain)
    local cmd = curl.build_request({
      url = util.api_url('sendMessage', bot_token),
      method = 'POST',
      headers = {
        'Content-Type: application/json',
      },
      stdin_body = true,
    })

    local response_chunks = {}
    local jobid = job.start(cmd, {
      raw = true,
      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          response_chunks[#response_chunks + 1] = chunk
        end
      end,
      on_stderr = function(_, data)
        for _, chunk in ipairs(data) do
          log.debug('[Telegram] ' .. chunk)
        end
      end,
      on_exit = function()
        send_message_jobid = -1
        dispatch_busy = false

        -- A 400 on a Markdown body is the "can't parse entities" case: resend
        -- the same chunk as plain text so the reply is not dropped.
        local ok, result = pcall(json.decode, table.concat(response_chunks, ''))
        if
          not plain
          and ok
          and type(result) == 'table'
          and result.ok == false
          and result.error_code == 400
        then
          log.warn(
            '[Telegram] Markdown rejected ('
              .. tostring(result.description)
              .. '), retrying as plain text'
          )
          start_send(item, true)
          return
        end

        dispatch_message()
      end,
    })

    -- A job that could not be spawned returns 0: no callback ever fires, so
    -- the claim has to be released here instead of staying taken forever.
    if not jobid or jobid <= 0 then
      send_message_jobid = -1
      dispatch_busy = false
      log.error('[Telegram] Skip send: failed to start the request')
      dispatch_message()
      return
    end

    send_message_jobid = jobid
    job.send(jobid, body)
    job.send(jobid, nil)
  end

  dispatch_message = function()
    if dispatch_busy or send_message_jobid > 0 then
      return
    end

    local item = table.remove(message_queue, 1)
    if not item then
      return
    end

    if not item.chat_id then
      log.error('[Telegram] Skip send: chat_id not configured')
      -- Without an address every chunk of this batch fails identically, so drop
      -- the queue instead of looping on it.
      message_queue = {}
      return
    end

    -- Claim the queue before the request starts.
    dispatch_busy = true
    start_send(item, false)
  end

  --- Send a reply.
  ---
    --- The optional `session` is the second argument the shared layer passes once
  --- an integration exposes bindings: replies then go back to the chat the
  --- request came from. A single-argument call addresses the main chat.
  --- @param content string
  --- @param session? string
  local function send_message(content, session)
    if type(content) ~= 'string' or content == '' then
      return
    end

    local chat_id = util.main_chat_id()
    if session then
      chat_id = ctx.container.session_to_chat(session) or chat_id
    end
    if not chat_id then
      log.error('[Telegram] Skip send: chat_id not configured')
      return
    end

    -- Single source of truth for the platform limit: chunker.Limits.TELEGRAM.
    local chunks = chunker.chunk(content, chunker.Limits.TELEGRAM)
    for _, chunk in ipairs(chunks) do
      table.insert(message_queue, { content = chunk, chat_id = chat_id })
    end

    dispatch_message()
  end

  --- Reply to a specific message (`reply_to_message_id`).
  ---
  --- Kept for API compatibility with the previous implementation; routing still
  --- follows the explicit `chat_id` the caller passes.
  --- @param chat_id string|number
  --- @param message_id string|number
  --- @param text string
  --- @return integer|nil jobid
  local function reply(chat_id, message_id, text)
    local bot_token = util.bot_token()
    if not bot_token then
      log.error('[Telegram] bot_token not configured')
      return nil
    end

    local body = json.encode({
      chat_id = util.id_to_string(chat_id),
      text = text,
      reply_to_message_id = message_id,
      parse_mode = 'Markdown',
    })
    local cmd = curl.build_request({
      url = util.api_url('sendMessage', bot_token),
      method = 'POST',
      headers = {
        'Content-Type: application/json',
      },
      body = body,
    })
    return job.start(cmd, {
      on_exit = function(id, code, signal)
        if code ~= 0 or signal ~= 0 then
          log.debug(
            string.format(
              '[Telegram] reply job %d exit with code %d signal %d',
              id,
              code,
              signal
            )
          )
        end
      end,
    })
  end

  return {
    send_message = send_message,
    reply = reply,
    dispatch_message = function()
      return dispatch_message()
    end,
  }
end

return M


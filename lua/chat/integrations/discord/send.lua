-- lua/chat/integrations/discord/send.lua
-- Outbound side: chunked, queued delivery to one channel, plus the typing
-- indicator and single-shot replies.
--
-- Queued chunks carry their own destination: two channels replying at the same
-- time must not leak chunks into each other.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local chunker = require('chat.utils.chunker')
local util = require('chat.integrations.discord.util')

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
  -- taken until its job exits, so a reply arriving in the same tick cannot
  -- start a second job and interleave the chunks of both batches.
  local dispatch_busy = false

  -- Forward declaration: abandon_dispatch and the job exit callback both re-enter
  -- the queue, and dispatch_queue itself is defined after them.
  local dispatch_queue

  --- Release the claim and serve whatever is left.
  ---
  --- Used when one chunk could not be started but the next one might: the
  --- claim has to be cleared, otherwise the queue stays owned forever and
  --- nothing is ever sent again.
  --- @param reason string
  local function abandon_dispatch(reason)
    log.error('[Discord] Skip send: ' .. reason)
    send_message_jobid = -1
    dispatch_busy = false
    dispatch_queue()
  end

  --- Channel a reply is addressed to.
  ---
  --- Discord takes the channel id for both guild channels and DMs; there is no
  --- separate `receive_id_type` as on Lark, so the target is just the id.
  --- @param channel_id string|nil
  --- @return string|nil
  local function send_target(channel_id)
    return channel_id
  end

  dispatch_queue = function()
    if dispatch_busy or send_message_jobid > 0 then
      log.debug('[Discord] dispatch: another job in progress')
      return
    end

    local item = table.remove(message_queue, 1)
    if not item then
      log.debug('[Discord] dispatch: queue is empty')
      return
    end

    local token = util.token()
    if not token then
      log.error('[Discord] Missing token')
      message_queue = {}
      return
    end

    local channel = send_target(item.channel_id)
    if not channel then
      -- Without an address every chunk of this batch fails identically, so drop
      -- the queue instead of looping on it.
      log.error('[Discord] Skip send: channel_id not configured')
      message_queue = {}
      return
    end

    dispatch_busy = true
    log.debug(
      string.format('[Discord] dispatch: sending message (%d bytes)', #item.content)
    )

    local body = json.encode({ content = item.content })
    local cmd = curl.build_request({
      url = util.API_BASE .. '/channels/' .. channel .. '/messages',
      method = 'POST',
      headers = {
        'Authorization: Bot ' .. token,
        'Content-Type: application/json',
      },
      stdin_body = true,
      connect_timeout = util.CONNECT_TIMEOUT,
      max_time = util.MAX_TIME,
    })

    local stderr_lines = {}
    local jobid = job.start(cmd, {
      on_stdout = function(_, data)
        for _, v in ipairs(data) do
          log.debug(v)
        end
      end,
      on_stderr = function(_, data)
        for _, v in ipairs(data) do
          log.debug(v)
          if v and v ~= '' then
            table.insert(stderr_lines, v)
          end
        end
      end,
      on_exit = function(_, code, single)
        log.debug(
          'discord send_message job exit ' .. code .. ' single ' .. single
        )
        if code ~= 0 or single ~= 0 then
          local reason = 'curl exit ' .. code
          if #stderr_lines > 0 then
            reason = reason .. ': ' .. table.concat(stderr_lines, ' ')
          end
          log.error('[Discord] Failed to send message (' .. reason .. ')')
        end
        send_message_jobid = -1
        dispatch_busy = false
        dispatch_queue()
      end,
    })

    -- A job that could not be spawned returns 0: no callback ever fires, so
    -- the claim has to be released here instead of staying taken forever.
    if not jobid or jobid <= 0 then
      abandon_dispatch('failed to start the request')
      return
    end

    send_message_jobid = jobid
    job.send(jobid, body)
    job.send(jobid, nil)
  end

  --- Send a reply.
  ---
  --- The optional `session` is the second argument the shared layer passes once
  --- an integration exposes bindings: replies then go back to the channel the
  --- request came from. A single-argument call (all existing call sites, and
  --- the in-chat `/status`, `/list` replies) addresses the main container.
  --- @param content string
  --- @param session? string
  local function send_message(content, session)
    if not content or content == '' then
      log.warn('[Discord] send_message called with empty content')
      return
    end

    log.debug(
      string.format('[Discord] send_message called (%d bytes)', #content)
    )

    local channel = util.main_channel_id()
    if session then
      channel = ctx.container.session_to_chat(session) or channel
    end

    if not channel then
      log.error('[Discord] Channel ID not configured')
      return
    end

    -- Single source of truth for the platform limit: chunker.Limits.DISCORD.
    local chunks = chunker.chunk(content, chunker.Limits.DISCORD)
    for _, chunk in ipairs(chunks) do
      table.insert(message_queue, { content = chunk, channel_id = channel })
    end

    dispatch_queue()
  end

  --- Post a message that is a Discord reply to a specific message.
  ---
  --- Kept as a standalone request (not queued): it is a one-shot answer whose
  --- `message_reference` makes the client thread it under the original message.
  --- @param channel string channel id
  --- @param message_id string message being replied to
  --- @param text string body
  --- @return integer|nil jobid
  local function reply(channel, message_id, text)
    local token = util.token()
    if not token then
      log.error('[Discord] Token not configured')
      return nil
    end

    local body = json.encode({
      content = text,
      message_reference = {
        message_id = message_id,
      },
    })
    local cmd = curl.build_request({
      url = util.API_BASE .. '/channels/' .. channel .. '/messages',
      method = 'POST',
      headers = {
        'Authorization: Bot ' .. token,
        'Content-Type: application/json',
      },
      body = body,
      connect_timeout = util.CONNECT_TIMEOUT,
      max_time = util.MAX_TIME,
    })
    local jobid = job.start(cmd, {
      on_exit = function(id, code, signal)
        if code ~= 0 or signal ~= 0 then
          log.error(
            string.format(
              '[Discord] Failed to send reply (job %d exit %d signal %d)',
              id,
              code,
              signal
            )
          )
        end
      end,
    })

    return jobid
  end

  --- Send a typing indicator to the channel the session talks in.
  ---
  --- The shared layer calls this with `true` while a response is streaming, and
  --- it passes no routing hint (`start_typing_timer` in
  --- chat/integrations/init.lua calls `integration.send_typing(true)`). So the
  --- channel is resolved in three steps:
  ---
  ---   1. the session, when one is given -- the same resolution `send_message`
  ---      uses, so the indicator lands where the reply will;
  ---   2. the channel of the most recent inbound message -- with several
  ---      containers, falling back to the main channel would show "typing…" in a
  ---      guild channel while a DM peer is waiting;
  ---   3. the configured main channel, for the first tick of a fresh start.
  --- @param is_typing boolean
  --- @param session? string routing hint (channel of the in-flight session)
  local function send_typing(is_typing, session)
    if not is_typing then
      return
    end

    local channel = nil
    if session then
      channel = ctx.container.session_to_chat(session)
    end
    channel = channel or state.last_active_channel or util.main_channel_id()
    local token = util.token()

    if not channel or not token then
      return
    end

    local cmd = curl.build_request({
      url = util.API_BASE .. '/channels/' .. channel .. '/typing',
      method = 'POST',
      headers = {
        'Authorization: Bot ' .. token,
      },
      connect_timeout = util.CONNECT_TIMEOUT,
      max_time = util.MAX_TIME,
    })
    job.start(cmd, {
      on_exit = function(id, code, signal)
        if code ~= 0 or signal ~= 0 then
          log.debug(
            string.format(
              'failed to send typing to discord channel, jobid: %d, exit code: %d, signal: %d',
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
    send_target = send_target,
    dispatch_queue = dispatch_queue,
    send_message = send_message,
    reply = reply,
    send_typing = send_typing,
  }
end

return M


-- lua/chat/integrations/lark/send.lua
-- Outbound side: chunked, queued delivery to one container.
--
-- Queued chunks carry their own destination: two chats replying at the same time
-- must not leak chunks into each other.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local auth = require('chat.integrations.lark.auth')
local chunker = require('chat.utils.chunker')
local util = require('chat.integrations.lark.util')

local json = vim.json

local M = {}

--- @param ctx table shared instance context
--- @return table send API
function M.new(ctx)
  local state = ctx.state
  local API_BASE = util.API_BASE

  local function ensure_token(callback)
    auth.ensure_token(callback)
  end

  -- Per-instance queue and in-flight job: a reload starts with an idle sender.
  local message_queue = {}
  local send_message_jobid = -1

  -- Whether a dispatch already owns the queue. Set from the moment the head is
  -- taken until its job exits, which is *earlier* than `send_message_jobid`:
  -- that field stays -1 while `ensure_token()` resolves the token
  -- asynchronously, so a second reply arriving inside that window would pass
  -- the jobid guard, start a second job, and interleave the chunks of both
  -- batches in the chat.
  local dispatch_busy = false

  -- Forward declaration: both helpers below re-enter the queue, and
  -- dispatch_message itself is defined after them.
  local dispatch_message

  --- Release the claim and serve whatever is left.
  ---
  --- Used when one chunk could not be started but the next one might: the
  --- claim has to be cleared, otherwise the queue stays owned forever and
  --- nothing is ever sent again.
  --- @param reason string
  local function abandon_dispatch(reason)
    log.error('[Lark] Skip send: ' .. reason)
    send_message_jobid = -1
    dispatch_busy = false
    dispatch_message()
  end

  --- Drop the whole queue after a failure that affects every chunk.
  ---
  --- A missing tenant token is a global condition: it fails for each queued
  --- chunk identically. Serving them one at a time asked for a token once per
  --- chunk and logged one error per chunk for a single outage, so the batch
  --- is dropped in one step with a single log line instead.
  --- @param reason string
  --- @param dropped integer chunks dropped, the one already taken included
  local function abandon_queue(reason, dropped)
    message_queue = {}
    send_message_jobid = -1
    dispatch_busy = false
    log.error(
      '[Lark] Skip send: '
        .. reason
        .. ' ('
        .. tostring(dropped)
        .. ' chunk(s) dropped)'
    )
  end

  --- Delivery address for one container.
  ---
  --- p2p replies go to the peer's open_id: an `oc_` id is only needed to *poll*
  --- a conversation, while `receive_id_type=open_id` addresses the person
  --- directly and survives container churn.
  --- @param chat_id string|nil
  --- @return table { id_type = string, receive_id = string|nil }
  local function send_target(chat_id)
    local ctr = chat_id and state.containers[chat_id] or nil
    if ctr and ctr.chat_type == 'p2p' and ctr.peer then
      return { id_type = 'open_id', receive_id = ctr.peer }
    end
    return { id_type = 'chat_id', receive_id = chat_id }
  end

  dispatch_message = function()
    if dispatch_busy or send_message_jobid > 0 then
      return
    end

    local item = table.remove(message_queue, 1)
    if not item then
      return
    end

    local target = send_target(item.chat_id)
    if not target.receive_id then
      log.error('[Lark] Skip send: chat_id not configured')
      -- Without an address every chunk of this batch fails identically, so drop
      -- the queue instead of looping on it.
      message_queue = {}
      return
    end

    -- Claim the queue before the asynchronous token lookup starts.
    dispatch_busy = true

    ensure_token(function(token, err)
      -- Token failure: no request is made, and it would fail for every queued
      -- chunk too. Drop the batch in one step instead of re-entering the
      -- queue, which requested a token again for each chunk and logged one
      -- error per chunk for a single outage.
      if not token then
        abandon_queue(err or 'no tenant_access_token', 1 + #message_queue)
        return
      end
      -- Use interactive card (schema 2.0) with markdown element,
      -- so markdown in AI replies is rendered by Lark clients.
      local body = json.encode({
        receive_id = target.receive_id,
        msg_type = 'interactive',
        content = json.encode({
          schema = '2.0',
          body = {
            elements = {
              {
                tag = 'markdown',
                content = item.content,
              },
            },
          },
        }),
      })
      local cmd = curl.build_request({
        url = API_BASE .. '/im/v1/messages?receive_id_type=' .. target.id_type,
        method = 'POST',
        headers = {
          'Authorization: Bearer ' .. token,
          'Content-Type: application/json',
        },
        stdin_body = true,
      })
      local jobid = job.start(cmd, {
        on_stdout = function(_, data)
          for _, v in ipairs(data) do
            log.debug(v)
          end
        end,
        on_stderr = function(_, data)
          for _, v in ipairs(data) do
            log.debug(v)
          end
        end,
        on_exit = function()
          send_message_jobid = -1
          dispatch_busy = false
          dispatch_message()
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
    end)
  end

  --- Send a reply.
  ---
  --- The optional `session` is the second argument the shared layer passes once
  --- an integration exposes bindings: replies then go back to the chat the
  --- request came from. A single-argument call (all existing call sites, and the
  --- in-chat `/status`, `/list` replies) addresses the main container.
  --- @param content string
  --- @param session? string
  local function send_message(content, session)
    local max_length = 30720 -- Lark message limit

    local chat_id = util.main_chat_id()
    if session then
      chat_id = ctx.container.session_to_chat(session) or chat_id
    end

    local chunks = chunker.chunk(content, max_length)
    for _, chunk in ipairs(chunks) do
      table.insert(message_queue, { content = chunk, chat_id = chat_id })
    end

    dispatch_message()
  end

  return {
    send_target = send_target,
    dispatch_message = dispatch_message,
    send_message = send_message,
  }
end

return M


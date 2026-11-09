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

  local function dispatch_message()
    if send_message_jobid > 0 then
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

    ensure_token(function(token, err)
      -- Token failure: no request is made. The queue has to be drained here,
      -- otherwise `send_message_jobid` stays -1 and every queued chunk below
      -- would wait for an on_exit that never fires.
      if not token then
        send_message_jobid = -1
        log.error('[Lark] Skip send: ' .. (err or 'no tenant_access_token'))
        dispatch_message()
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
      send_message_jobid = job.start(cmd, {
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
          dispatch_message()
        end,
      })

      job.send(send_message_jobid, body)
      job.send(send_message_jobid, nil)
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


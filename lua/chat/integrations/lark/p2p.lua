-- lua/chat/integrations/lark/p2p.lua
-- Private (1:1) chats: opening them from this side and provisioning the curated
-- set on connect.
--
-- A polling bot can not learn a p2p `oc_` id from an incoming message: it has
-- no cursor for a conversation it does not know about yet. So the conversation
-- is created from this side instead.
local log = require('chat.log')
local job = require('job')
local curl = require('chat.curl')
local auth = require('chat.integrations.lark.auth')
local util = require('chat.integrations.lark.util')

local json = vim.json

local M = {}

--- @param ctx table shared instance context
--- @return table p2p API
function M.new(ctx)
  local state = ctx.state
  local API_BASE = util.API_BASE

  local function save_state()
    return ctx.save_state()
  end

  local function ensure_token(callback)
    auth.ensure_token(callback)
  end

  --- The p2p container that already belongs to an open_id, if any.
  --- @param open_id string
  --- @return string|nil chat_id
  local function p2p_container_of(open_id)
    local found
    for chat_id, ctr in pairs(state.containers) do
      if ctr.chat_type == 'p2p' and ctr.peer == open_id then
        found = chat_id
        break
      end
    end
    return found
  end

  --- Open (or reuse) a 1:1 chat with an open_id.
  ---
  --- The conversation is created from this side:
  ---
  ---   1. POST /im/v1/messages?receive_id_type=open_id  (a greeting)
  ---   2. GET  /im/v1/messages/{message_id}            → `chat_id`
  ---   3. register that chat_id as a p2p container
  ---
  --- Step 1 doubles as the greeting the user sees, so nothing is sent twice. The
  --- bot's own `sender_type == 'app'` greeting is skipped by the poll loop, so no
  --- self-reply loop can start either.
  ---
  --- `callback` must fire exactly once on every path, including the ones where
  --- neither request is ever made: `provision_p2p()` chains its walk from it, so
  --- a silent path stops the whole provisioning run.
  --- @param open_id string
  --- @param callback? fun(ok: boolean, result: string)
  local function create_p2p(open_id, callback)
    callback = callback or function() end

    if type(open_id) ~= 'string' or open_id == '' then
      callback(false, 'open_id is required')
      return
    end

    if not ctx.acl.is_p2p_allowed(open_id) then
      callback(false, 'open_id is not allowed to use private chat')
      return
    end

    for chat_id, ctr in pairs(state.containers) do
      if ctr.chat_type == 'p2p' and ctr.peer == open_id then
        callback(true, chat_id)
        return
      end
    end

    local greeting = util.p2p_config().greeting
      or 'Hi, this is the chat.nvim bot. Reply here to talk to Neovim.'

    ensure_token(function(token, err)
      if not token then
        callback(false, err or 'no tenant_access_token')
        return
      end

      local body = json.encode({
        receive_id = open_id,
        msg_type = 'text',
        content = json.encode({ text = greeting }),
      })
      local send_cmd = curl.build_request({
        url = API_BASE .. '/im/v1/messages?receive_id_type=open_id',
        method = 'POST',
        headers = {
          'Authorization: Bearer ' .. token,
          'Content-Type: application/json',
        },
        stdin_body = true,
      })

      local chunks = {}
      local send_jobid = job.start(send_cmd, {
        on_stdout = function(_, data)
          for _, chunk in ipairs(data) do
            table.insert(chunks, chunk)
          end
        end,
        on_exit = function()
          local ok, result = pcall(json.decode, table.concat(chunks))
          if not ok or (result.code and result.code ~= 0) then
            callback(false, 'send failed: ' .. (ok and result.msg or 'bad json'))
            return
          end
          local message_id = result.data and result.data.message_id
          if not message_id then
            callback(false, 'message_id missing from the response')
            return
          end

          -- Read the created message back: its chat_id is the p2p container.
          local reveal_cmd = curl.build_request({
            url = API_BASE .. '/im/v1/messages/' .. message_id,
            method = 'GET',
            headers = { 'Authorization: Bearer ' .. token },
          })
          local reveal_chunks = {}
          local reveal_jobid = job.start(reveal_cmd, {
            on_stdout = function(_, data)
              for _, chunk in ipairs(data) do
                table.insert(reveal_chunks, chunk)
              end
            end,
            on_exit = function()
              local ok2, res2 =
                pcall(json.decode, table.concat(reveal_chunks))
              if not ok2 or (res2.code and res2.code ~= 0) then
                callback(
                  false,
                  'lookup failed: ' .. (ok2 and res2.msg or 'bad json')
                )
                return
              end
              local item = res2.data and res2.data.items and res2.data.items[1]
              local chat_id = item and item.chat_id
              if not chat_id then
                callback(false, 'chat_id missing from the message detail')
                return
              end
              ctx.container.ensure_container(chat_id, {
                chat_type = 'p2p',
                peer = open_id,
              })
              save_state()
              log.info('[Lark] p2p chat ready: ' .. chat_id)
              callback(true, chat_id)
            end,
          })

          -- A job that could not be spawned returns 0: its on_exit never
          -- fires, so without this check the chain (and provision_p2p() behind
          -- it) would stop here forever.
          if not reveal_jobid or reveal_jobid <= 0 then
            callback(false, 'failed to start the message lookup')
            return
          end
        end,
      })

      -- Same here: the greeting request is what creates the conversation, so
      -- a failed spawn means there is nothing to observe and nobody to notify
      -- unless the callback is fired explicitly.
      if not send_jobid or send_jobid <= 0 then
        callback(false, 'failed to start the greeting request')
        return
      end

      job.send(send_jobid, body)
      job.send(send_jobid, nil)
    end)
  end

  --- Make sure every curated open_id owns a p2p container.
  ---
  --- A p2p conversation is only polled once its `oc_` id is registered, and a
  --- polling bot can not learn that id from an incoming message. So the chats
  --- are opened proactively: an admin listed in `p2p.allow` (or, without that
  --- list, `acl.admins`) gets a container on connect without lifting a finger.
  ---
  --- Cheap and idempotent: a known container is a pure table lookup, and
  --- `create_p2p` answers synchronously for it (no greeting is re-sent). Every
  --- provisioned container also gets its own session immediately, so
  --- `/session` style commands work before the first message arrives.
  ---
  --- `p2p.auto_create = false` turns the whole thing off.
  --- @param open_ids? string[] Defaults to `get_p2p_provision_list()`
  --- @param callback? fun() Called once the list has been walked
  local function provision_p2p(open_ids, callback)
    callback = callback or function() end

    if util.p2p_config().auto_create == false then
      callback()
      return
    end

    if not state.is_running then
      -- Nothing to provision for: the poller is not reading anything, and
      -- `connect()` provisions on its own.
      callback()
      return
    end

    local list = open_ids or ctx.acl.get_p2p_provision_list()
    if type(list) == 'string' then
      list = { list }
    end

    local index = 0
    local function next_open_id()
      index = index + 1
      if index > #list then
        callback()
        return
      end

      local open_id = list[index]
      if type(open_id) ~= 'string' or open_id == '' then
        next_open_id()
        return
      end

      -- Known peer: create_p2p would answer synchronously anyway, but a table
      -- lookup keeps the log free of a "already known" entry per connect.
      if p2p_container_of(open_id) then
        next_open_id()
        return
      end

      create_p2p(open_id, function(ok, result)
        if ok then
          local ctr = state.containers[result]
          if ctr then
            -- Bind the session now: a container that arrives with history but
            -- no session would otherwise borrow the platform session.
            ctx.container.ensure_container_session(result, ctr)
          end
          log.info(
            '[Lark] Provisioned p2p chat for '
              .. open_id
              .. ': '
              .. tostring(result)
          )
        else
          -- debug, not error: a user who never talked to the bot, or a missing
          -- `im:message:send_as_bot` scope, is a normal outcome and the next
          -- connect retries it.
          log.debug(
            '[Lark] p2p provisioning skipped ('
              .. open_id
              .. '): '
              .. tostring(result)
          )
        end
        next_open_id()
      end)
    end

    next_open_id()
  end

  return {
    p2p_container_of = p2p_container_of,
    create_p2p = create_p2p,
    provision_p2p = provision_p2p,
  }
end

return M


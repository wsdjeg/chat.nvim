-- lua/chat/integrations/weixin/state.lua
-- State management for WeChat integration

local M = {}

local log = require('chat.log')
local json = vim.json
local uv = vim.uv

local STATE_FILE = vim.fn.stdpath('data') .. '/chat-weixin-state.json'

local TYPING_TICKET_TTL_MS = 24 * 60 * 60 * 1000 -- 24小时

-- Internal state
local state = {
  -- Connection state
  is_running = false,
  is_polling = false,

  -- Sync cursor for long-polling
  get_updates_buf = '',

  -- Context tokens per user (for reply)
  context_tokens = {},

  -- Typing tickets per user (for typing indicator)
  typing_tickets = {}, -- {[user_id] = {ticket = "xxx", fetched_at = timestamp}}

  -- Current session binding
  session = nil,

  -- Timer reference
  timer = nil,

  -- Callback
  callback = nil,

  -- Login credentials
  bot_token = nil,
  account_id = nil,
  base_url = nil,
  user_id = nil,

  -- Last sender user_id (for reply)
  last_from_user_id = nil,
}

--------------------------------------------------
-- Save state to disk
--------------------------------------------------
function M.save()
  local data = {
    get_updates_buf = state.get_updates_buf,
    context_tokens = state.context_tokens,
    session = state.session,
    -- 保存登录凭证
    bot_token = state.bot_token,
    account_id = state.account_id,
    base_url = state.base_url,
    user_id = state.user_id,
    -- 保存最后发送者 ID
    last_from_user_id = state.last_from_user_id,
    -- 保存 typing tickets
    typing_tickets = state.typing_tickets,
  }

  local ok, encoded = pcall(json.encode, data)
  if not ok then
    log.error('[Weixin] Failed to encode state')
    return false
  end

  local dir = vim.fn.fnamemodify(STATE_FILE, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local file, err = io.open(STATE_FILE, 'w')
  if not file then
    log.error('[Weixin] Failed to save state: ' .. (err or 'unknown'))
    return false
  end

  file:write(encoded)
  file:close()
  log.debug('[Weixin] State saved')
  return true
end

--------------------------------------------------
-- Load state from disk
--------------------------------------------------
function M.load()
  local file = io.open(STATE_FILE, 'r')
  if not file then
    return false
  end

  local content = file:read('*a')
  file:close()

  if not content or content == '' then
    return false
  end

  local ok, data = pcall(json.decode, content)
  if not ok or not data then
    return false
  end

  state.get_updates_buf = data.get_updates_buf or ''
  state.context_tokens = data.context_tokens or {}
  state.session = data.session
  -- 加载登录凭证
  state.bot_token = data.bot_token
  state.account_id = data.account_id
  state.base_url = data.base_url
  state.user_id = data.user_id
  -- 加载最后发送者 ID
  state.last_from_user_id = data.last_from_user_id
  -- 加载 typing tickets
  state.typing_tickets = data.typing_tickets or {}

  log.debug('[Weixin] State loaded')
  return true
end

--------------------------------------------------
-- Clear state
--------------------------------------------------
function M.clear()
  state.get_updates_buf = ''
  state.context_tokens = {}
  state.typing_tickets = {}
  state.session = nil
  -- 清除登录凭证
  state.bot_token = nil
  state.account_id = nil
  state.base_url = nil
  state.user_id = nil
  -- 清除最后发送者 ID
  state.last_from_user_id = nil
  os.remove(STATE_FILE)
  log.info('[Weixin] State cleared')
end

--------------------------------------------------
-- Getters and setters
--------------------------------------------------
function M.get()
  return state
end

function M.set_running(running)
  state.is_running = running
end

function M.set_polling(polling)
  state.is_polling = polling
end

function M.set_timer(timer)
  state.timer = timer
end

function M.set_callback(callback)
  state.callback = callback
end

function M.get_callback()
  return state.callback
end

function M.set_session(session)
  state.session = session
  M.save()
end

function M.get_session()
  return state.session
end

function M.is_running()
  return state.is_running
end

function M.is_polling()
  return state.is_polling
end

function M.get_updates_buf()
  return state.get_updates_buf
end

function M.set_updates_buf(buf)
  state.get_updates_buf = buf
end

function M.get_context_token(user_id)
  return state.context_tokens[user_id]
end

function M.set_context_token(user_id, token)
  state.context_tokens[user_id] = token
end

function M.set_typing_ticket(user_id, ticket)
  state.typing_tickets[user_id] = {
    ticket = ticket,
    fetched_at = uv.now(),
  }
end

function M.get_typing_ticket(user_id)
  local entry = state.typing_tickets[user_id]
  if not entry then
    return nil
  end
  -- 检查过期
  if uv.now() - entry.fetched_at > TYPING_TICKET_TTL_MS then
    state.typing_tickets[user_id] = nil
    return nil
  end
  return entry.ticket
end

function M.get_timer()
  return state.timer
end

-- 登录凭证相关 getter/setter
function M.get_credentials()
  return {
    bot_token = state.bot_token,
    account_id = state.account_id,
    base_url = state.base_url,
    user_id = state.user_id,
  }
end

function M.set_credentials(credentials)
  state.bot_token = credentials.bot_token
  state.account_id = credentials.account_id
  state.base_url = credentials.base_url
  state.user_id = credentials.user_id
end

function M.has_credentials()
  return state.bot_token ~= nil and state.account_id ~= nil
end

-- 最后发送者 ID 相关 getter/setter
function M.get_last_from_user_id()
  return state.last_from_user_id
end

function M.set_last_from_user_id(user_id)
  state.last_from_user_id = user_id
  M.save()
end

--------------------------------------------------
-- Get state info for debugging
--------------------------------------------------
function M.get_info()
  return {
    is_running = state.is_running,
    is_polling = state.is_polling,
    has_updates_buf = #state.get_updates_buf > 0,
    context_token_count = vim.tbl_count(state.context_tokens),
    typing_ticket_count = vim.tbl_count(state.typing_tickets),
    session = state.session,
    has_credentials = M.has_credentials(),
    last_from_user_id = state.last_from_user_id,
  }
end

return M

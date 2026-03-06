local M = {}

local config = require("chat.config")
local log = require("chat.log")
local job = require("job")

local json = vim.json
local uv = vim.uv

--------------------------------------------------
-- state
--------------------------------------------------

local state = {
  jobid = nil,
  heartbeat = nil,

  seq = nil,
  bot_id = nil,

  callback = nil
}

--------------------------------------------------
-- send gateway payload
--------------------------------------------------

local function send(payload)

  if not state.jobid then
    return
  end

  job.send(state.jobid, json.encode(payload) .. "\n")

end

--------------------------------------------------
-- heartbeat
--------------------------------------------------

local function start_heartbeat(interval)

  if state.heartbeat then
    state.heartbeat:stop()
  end

  state.heartbeat = uv.new_timer()

  state.heartbeat:start(
    interval,
    interval,
    vim.schedule_wrap(function()

      send({
        op = 1,
        d = state.seq
      })

    end)
  )

end

--------------------------------------------------
-- check mention
--------------------------------------------------

local function is_for_bot(msg)

  if msg.mentions then
    for _,m in ipairs(msg.mentions) do
      if m.id == state.bot_id then
        return true
      end
    end
  end

  if msg.referenced_message then
    local a = msg.referenced_message.author
    if a and a.id == state.bot_id then
      return true
    end
  end

  return false

end

--------------------------------------------------
-- gateway event
--------------------------------------------------

local function handle_event(data)

  if data.s then
    state.seq = data.s
  end

  ------------------------------------------------
  -- HELLO
  ------------------------------------------------

  if data.op == 10 then

    start_heartbeat(data.d.heartbeat_interval)

    send({
      op = 2,
      d = {
        token = config.config.integrations.discord.token,
        intents = 513,
        properties = {
          os = "linux",
          browser = "chat.nvim",
          device = "chat.nvim"
        }
      }
    })

    return
  end

  ------------------------------------------------
  -- HEARTBEAT ACK
  ------------------------------------------------

  if data.op == 11 then
    return
  end

  ------------------------------------------------
  -- DISPATCH
  ------------------------------------------------

  if data.op ~= 0 then
    return
  end

  ------------------------------------------------
  -- READY
  ------------------------------------------------

  if data.t == "READY" then

    state.bot_id = data.d.user.id

    log.debug("discord ready bot_id=" .. state.bot_id)

    return
  end

  ------------------------------------------------
  -- MESSAGE_CREATE
  ------------------------------------------------

  if data.t == "MESSAGE_CREATE" then

    local msg = data.d

    if msg.author.bot then
      return
    end

    if not is_for_bot(msg) then
      return
    end

    local content = msg.content
      :gsub("<@!?%d+>", "")
      :gsub("^%s+", "")

    local out = {
      author = msg.author.username,
      content = content,
      channel_id = msg.channel_id,
      message_id = msg.id,
      reply = msg.referenced_message ~= nil
    }

    if state.callback then
      vim.schedule(function()
        state.callback(out)
      end)
    end

  end

end

--------------------------------------------------
-- connect gateway
--------------------------------------------------

function M.connect(callback)

  state.callback = callback

  state.jobid = job.start(
  {
    "curl",
    "-N",
    "-s",
    "wss://gateway.discord.gg/?v=10&encoding=json"
  },
  {
    stdout = function(line)

      if not line or line == "" then
        return
      end

      local ok,data = pcall(json.decode,line)

      if not ok then
        return
      end

      handle_event(data)

    end,

    stderr = function(line)
      log.error(line)
    end
  })

end

--------------------------------------------------
-- send message
--------------------------------------------------

function M.send_message(content)

  local channel = config.config.integrations.discord.channel_id
  local token = config.config.integrations.discord.token

  if not channel or not token then
    return
  end

  local cmd = {
    "curl",
    "-s",
    "https://discord.com/api/v10/channels/"..channel.."/messages",
    "-H","Authorization: Bot "..token,
    "-H","Content-Type: application/json",
    "-X","POST",
    "-d","@-"
  }

  local id = job.start(cmd)

  job.send(id,json.encode({
    content = content
  }))

  job.send(id,nil)

end

--------------------------------------------------
-- reply message
--------------------------------------------------

function M.reply(channel,message_id,text)

  local token = config.config.integrations.discord.token

  local cmd = {
    "curl",
    "-s",
    "https://discord.com/api/v10/channels/"..channel.."/messages",
    "-H","Authorization: Bot "..token,
    "-H","Content-Type: application/json",
    "-X","POST",
    "-d","@-"
  }

  local id = job.start(cmd)

  job.send(id,json.encode({

    content = text,

    message_reference = {
      message_id = message_id
    }

  }))

  job.send(id,nil)

end

--------------------------------------------------

function M.receive_messages(cb)
  M.connect(cb)
end

return M

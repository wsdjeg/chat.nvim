local M = {}

local config = require("chat.config")
local log = require("chat.log")
local job = require("job")

local json = vim.json
local uv = vim.uv
local bit = bit

local WS_OPCODE_TEXT = 0x1
local WS_OPCODE_CLOSE = 0x8
local WS_OPCODE_PING = 0x9
local WS_OPCODE_PONG = 0xA

local ws_state = {
  tcp = nil,
  tls = nil,
  heartbeat_timer = nil,
  session_id = nil,
  sequence = nil,
  callback = nil,
}

--------------------------------------------------
-- WebSocket encode
--------------------------------------------------

local function encode_frame(payload, opcode)
  opcode = opcode or WS_OPCODE_TEXT

  local frame = {}
  local len = #payload

  table.insert(frame, string.char(bit.bor(0x80, opcode)))

  local mask_bit = 0x80

  if len <= 125 then
    table.insert(frame, string.char(bit.bor(mask_bit, len)))
  elseif len <= 65535 then
    table.insert(frame, string.char(bit.bor(mask_bit, 126)))
    table.insert(frame, string.char(bit.rshift(len, 8)))
    table.insert(frame, string.char(bit.band(len, 0xff)))
  else
    error("payload too large")
  end

  local mask = string.char(
    math.random(0,255),
    math.random(0,255),
    math.random(0,255),
    math.random(0,255)
  )

  table.insert(frame, mask)

  local masked = {}

  for i = 1, len do
    local b = string.byte(payload, i)
    local m = string.byte(mask, ((i-1)%4)+1)
    masked[i] = string.char(bit.bxor(b,m))
  end

  table.insert(frame, table.concat(masked))

  return table.concat(frame)
end

--------------------------------------------------
-- WebSocket decode
--------------------------------------------------

local function decode_frame(data)

  if #data < 2 then return nil end

  local b1 = string.byte(data,1)
  local b2 = string.byte(data,2)

  local opcode = bit.band(b1,0x0f)
  local len = bit.band(b2,0x7f)

  local offset = 3

  if len == 126 then
    if #data < 4 then return nil end
    len = bit.bor(
      bit.lshift(string.byte(data,3),8),
      string.byte(data,4)
    )
    offset = 5
  end

  if #data < offset + len - 1 then
    return nil
  end

  local payload = string.sub(data,offset,offset+len-1)

  return {
    opcode = opcode,
    payload = payload,
    remaining = string.sub(data,offset+len)
  }

end

--------------------------------------------------
-- send
--------------------------------------------------

local function ws_send(data,opcode)
  local frame = encode_frame(data,opcode)
  ws_state.tls:write(frame)
end

--------------------------------------------------
-- gateway events
--------------------------------------------------

local function handle_gateway_event(payload)

  local ok,data = pcall(json.decode,payload)
  if not ok then return end

  if data.s then
    ws_state.sequence = data.s
  end

  if data.op == 10 then

    local interval = data.d.heartbeat_interval

    ws_state.heartbeat_timer = uv.new_timer()

    ws_state.heartbeat_timer:start(
      interval,
      interval,
      vim.schedule_wrap(function()

        local hb = json.encode({
          op = 1,
          d = ws_state.sequence
        })

        ws_send(hb)

      end)
    )

    local identify = json.encode({
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

    ws_send(identify)

  elseif data.op == 11 then
    log.debug("heartbeat ack")

  elseif data.op == 0 then

    if data.t == "READY" then
      ws_state.session_id = data.d.session_id
      log.debug("discord ready")

    elseif data.t == "MESSAGE_CREATE" then

      if data.d.author.bot then
        return
      end

      local msg = {
        author = data.d.author.username,
        content = data.d.content,
        channel_id = data.d.channel_id,
        timestamp = data.d.timestamp
      }

      if ws_state.callback then
        vim.schedule(function()
          ws_state.callback(msg)
        end)
      end

    end
  end

end

--------------------------------------------------
-- read loop
--------------------------------------------------

local function start_read()

  local buffer = ""

  ws_state.tls:read_start(vim.schedule_wrap(function(err,data)

    if err then
      log.error(err)
      return
    end

    if not data then
      log.debug("socket closed")
      return
    end

    buffer = buffer .. data

    local header_end = buffer:find("\r\n\r\n")

    if header_end then
      buffer = buffer:sub(header_end+4)
    end

    while true do

      local frame = decode_frame(buffer)

      if not frame then break end

      buffer = frame.remaining or ""

      if frame.opcode == WS_OPCODE_TEXT then
        handle_gateway_event(frame.payload)

      elseif frame.opcode == WS_OPCODE_PING then
        ws_send(frame.payload,WS_OPCODE_PONG)

      elseif frame.opcode == WS_OPCODE_CLOSE then
        log.debug("ws close")
        return
      end

    end

  end))

end

--------------------------------------------------
-- handshake
--------------------------------------------------

local function handshake()

  local key = vim.base64.encode(tostring(os.time()))

  local req = table.concat({
    "GET /?v=10&encoding=json HTTP/1.1",
    "Host: gateway.discord.gg",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Key: "..key,
    "User-Agent: chat.nvim",
    "\r\n"
  },"\r\n")

  ws_state.tls:write(req)

end

--------------------------------------------------
-- connect
--------------------------------------------------

function M.connect(callback)

  ws_state.callback = callback

  ws_state.tcp = uv.new_tcp()

  uv.getaddrinfo(
    "gateway.discord.gg",
    443,
    {family="inet"},
    function(err,addrs)

      if err then
        log.error(err)
        return
      end

      local addr = addrs[1]

      ws_state.tcp:connect(addr.addr,addr.port,function(err)

        if err then
          log.error(err)
          return
        end

        ws_state.tls = uv.new_tls({
          servername="gateway.discord.gg"
        })

        ws_state.tls:handshake(ws_state.tcp,function(err)

          if err then
            log.error(err)
            return
          end

          start_read()
          handshake()

        end)

      end)

    end
  )

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

  local jobid = job.start(cmd)

  job.send(jobid,json.encode({
    content = content
  }))

  job.send(jobid,nil)

end

--------------------------------------------------

function M.receive_messages(cb)
  M.connect(cb)
end

return M

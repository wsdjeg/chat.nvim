local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

local json = vim.json
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
-- encode websocket frame
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
    table.insert(frame, string.char(math.floor(len / 256)))
    table.insert(frame, string.char(len % 256))
  else
    error("Payload too large")
  end

  local mask_key = string.char(
    math.random(0,255),
    math.random(0,255),
    math.random(0,255),
    math.random(0,255)
  )

  table.insert(frame, mask_key)

  local masked = {}

  for i = 1, len do
    local byte = string.byte(payload, i)
    local mask_byte = string.byte(mask_key, ((i - 1) % 4) + 1)
    masked[i] = string.char(bit.bxor(byte, mask_byte))
  end

  table.insert(frame, table.concat(masked))

  return table.concat(frame)
end

--------------------------------------------------
-- decode frame
--------------------------------------------------

local function decode_frame(data)

  if #data < 2 then
    return nil
  end

  local offset = 1

  local byte1 = string.byte(data, offset)
  local byte2 = string.byte(data, offset + 1)

  local opcode = bit.band(byte1, 0x0F)
  local masked = bit.band(byte2, 0x80) ~= 0
  local payload_len = bit.band(byte2, 0x7F)

  offset = offset + 2

  if payload_len == 126 then
    if #data < offset + 1 then return nil end

    payload_len =
      bit.lshift(string.byte(data, offset), 8)
      + string.byte(data, offset + 1)

    offset = offset + 2

  elseif payload_len == 127 then
    return nil
  end

  local mask_key = nil

  if masked then
    if #data < offset + 3 then return nil end
    mask_key = string.sub(data, offset, offset + 3)
    offset = offset + 4
  end

  if #data < offset + payload_len - 1 then
    return nil
  end

  local payload = string.sub(data, offset, offset + payload_len - 1)

  if mask_key then

    local unmasked = {}

    for i = 1, #payload do
      local byte = string.byte(payload, i)
      local mask_byte = string.byte(mask_key, ((i - 1) % 4) + 1)
      unmasked[i] = string.char(bit.bxor(byte, mask_byte))
    end

    payload = table.concat(unmasked)

  end

  return {
    opcode = opcode,
    payload = payload,
    remaining = string.sub(data, offset + payload_len)
  }

end

--------------------------------------------------
-- send websocket
--------------------------------------------------

local function ws_send(data, opcode)

  local frame = encode_frame(data, opcode)
  ws_state.tls:write(frame)

end

--------------------------------------------------
-- gateway event
--------------------------------------------------

local function handle_gateway_event(payload)

  local ok, data = pcall(json.decode, payload)
  if not ok or not data then
    return
  end

  if data.s then
    ws_state.sequence = data.s
  end

  if data.op == 10 then

    local interval = data.d.heartbeat_interval

    ws_state.heartbeat_timer = vim.uv.new_timer()

    ws_state.heartbeat_timer:start(
      interval,
      interval,
      vim.schedule_wrap(function()

        ws_send(json.encode({
          op = 1,
          d = ws_state.sequence
        }))

      end)
    )

    ws_send(json.encode({
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
    }))

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

      log.debug(msg.author .. ": " .. msg.content)

      if ws_state.callback then
        vim.schedule(function()
          ws_state.callback(msg)
        end)
      end

    end

  end

end

--------------------------------------------------
-- websocket handshake
--------------------------------------------------

local function perform_handshake()

  local key = vim.base64.encode(tostring(os.time()) .. tostring(math.random()))

  local handshake =
    "GET /?v=10&encoding=json HTTP/1.1\r\n"
    .. "Host: gateway.discord.gg\r\n"
    .. "Upgrade: websocket\r\n"
    .. "Connection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: " .. key .. "\r\n"
    .. "Sec-WebSocket-Version: 13\r\n"
    .. "User-Agent: chat.nvim\r\n"
    .. "\r\n"

  ws_state.tls:write(handshake)

end

--------------------------------------------------
-- read loop
--------------------------------------------------

local function start_read_loop()

  local buffer = ""

  ws_state.tls:read_start(vim.schedule_wrap(function(err, data)

    if err then
      log.error(err)
      return
    end

    if not data then
      return
    end

    buffer = buffer .. data

    if buffer:find("HTTP/1.1 101") and buffer:find("\r\n\r\n") then

      local pos = buffer:find("\r\n\r\n")
      buffer = buffer:sub(pos + 4)

      log.debug("websocket connected")

    end

    while true do

      local frame = decode_frame(buffer)

      if not frame then
        break
      end

      buffer = frame.remaining or ""

      if frame.opcode == WS_OPCODE_TEXT then

        handle_gateway_event(frame.payload)

      elseif frame.opcode == WS_OPCODE_PING then

        ws_send(frame.payload, WS_OPCODE_PONG)

      elseif frame.opcode == WS_OPCODE_CLOSE then

        log.debug("ws close")
        return

      end

    end

  end))

end

--------------------------------------------------
-- connect gateway
--------------------------------------------------

function M.connect(callback)

  ws_state.callback = callback

  ws_state.tcp = vim.uv.new_tcp()

  vim.uv.getaddrinfo("gateway.discord.gg", 443, {}, function(err, addr)

    if err then
      log.error(err)
      return
    end

    ws_state.tcp:connect(addr[1].addr, addr[1].port, function(connect_err)

      if connect_err then
        log.error(connect_err)
        return
      end

      ws_state.tls = vim.uv.new_tls({
        servername = "gateway.discord.gg"
      })

      ws_state.tls:handshake(ws_state.tcp, function(tls_err)

        if tls_err then
          log.error(tls_err)
          return
        end

        start_read_loop()
        perform_handshake()

      end)

    end)

  end)

end

--------------------------------------------------
-- send message
--------------------------------------------------

function M.send_message(content)

  if
    not config.config.integrations.discord.channel_id
    or not config.config.integrations.discord.token
  then
    return
  end

  local cmd = {
    'curl',
    '-s',
    'https://discord.com/api/v10/channels/'
      .. config.config.integrations.discord.channel_id
      .. '/messages',
    '-H',
    'Authorization: Bot ' .. config.config.integrations.discord.token,
    '-H',
    'Content-Type: application/json',
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local jobid = job.start(cmd, {})

  job.send(jobid, json.encode({
    content = content,
  }))

  job.send(jobid, nil)

end

--------------------------------------------------

function M.receive_messages(callback)
  return M.connect(callback)
end

return M

local M = {}

local config = require('chat.config')
local log = require('chat.log')
local job = require('job')

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
  session_id = nil,

  callback = nil,

  buffer = '',
  handshake_buffer = '',
  handshake_complete = false,

  last_heartbeat_ack = 0,
  missed_heartbeats = 0,

  reconnect_attempts = 0,
  is_connecting = false,
}

--------------------------------------------------
-- WebSocket frame parser
--------------------------------------------------

local function parse_frames(data)
  state.buffer = state.buffer .. data
  local frames = {}

  while #state.buffer >= 2 do
    local byte1 = state.buffer:byte(1)
    local fin = bit.band(byte1, 0x80) ~= 0
    local opcode = bit.band(byte1, 0x0F)

    local byte2 = state.buffer:byte(2)
    local mask = bit.band(byte2, 0x80) ~= 0
    local payload_len = bit.band(byte2, 0x7F)

    local header_len = 2

    if payload_len == 126 then
      if #state.buffer < 4 then
        break
      end

      header_len = 4
      payload_len =
        bit.bor(bit.lshift(state.buffer:byte(3), 8), state.buffer:byte(4))
    elseif payload_len == 127 then
      if #state.buffer < 10 then
        break
      end

      header_len = 10
      payload_len = bit.bor(
        bit.lshift(state.buffer:byte(7), 24),
        bit.lshift(state.buffer:byte(8), 16),
        bit.lshift(state.buffer:byte(9), 8),
        state.buffer:byte(10)
      )
    end

    if mask then
      header_len = header_len + 4
    end

    if #state.buffer < header_len + payload_len then
      break
    end

    local payload

    if mask then
      local mask_key = state.buffer:sub(header_len - 3, header_len)

      payload = ''

      local payload_start = header_len

      for i = 0, payload_len - 1 do
        local byte = state.buffer:byte(payload_start + i)
        local mask_byte = mask_key:byte((i % 4) + 1)

        payload = payload .. string.char(bit.bxor(byte, mask_byte))
      end
    else
      payload = state.buffer:sub(header_len + 1, header_len + payload_len)
    end

    table.insert(frames, {
      opcode = opcode,
      payload = payload,
      fin = fin,
    })

    state.buffer = state.buffer:sub(header_len + payload_len + 1)
  end

  return frames
end

local OPCODE = {
  TEXT = 0x1,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

--------------------------------------------------
-- send websocket payload
--------------------------------------------------

local function send(payload)
  if not state.jobid then
    return
  end

  local data = json.encode(payload)

  local frame = string.char(0x81)
  local len = #data

  if len <= 125 then
    frame = frame .. string.char(0x80 + len)
  elseif len <= 65535 then
    frame = frame .. string.char(0x80 + 126)
    frame = frame .. string.char(bit.band(bit.rshift(len, 8), 0xFF))
    frame = frame .. string.char(bit.band(len, 0xFF))
  else
    frame = frame .. string.char(0x80 + 127)
    frame = frame .. string.char(0, 0, 0, 0)
    frame = frame .. string.char(bit.band(bit.rshift(len, 24), 0xFF))
    frame = frame .. string.char(bit.band(bit.rshift(len, 16), 0xFF))
    frame = frame .. string.char(bit.band(bit.rshift(len, 8), 0xFF))
    frame = frame .. string.char(bit.band(len, 0xFF))
  end

  local mask_key = string.char(
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255)
  )

  frame = frame .. mask_key

  for i = 1, #data do
    local byte = data:byte(i)
    local mask_byte = mask_key:byte(((i - 1) % 4) + 1)

    frame = frame .. string.char(bit.bxor(byte, mask_byte))
  end

  job.send(state.jobid, frame)
end

--------------------------------------------------
-- heartbeat
--------------------------------------------------

local function start_heartbeat(interval)
  if state.heartbeat then
    state.heartbeat:stop()
  end

  state.heartbeat = uv.new_timer()

  state.last_heartbeat_ack = uv.now()

  state.heartbeat:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      local elapsed = uv.now() - state.last_heartbeat_ack

      if elapsed > interval * 2 then
        log.warn('Missed heartbeat ACK')

        job.stop(state.jobid)

        return
      end

      send({
        op = 1,
        d = state.seq,
      })
    end)
  )
end

--------------------------------------------------
-- process websocket frames
--------------------------------------------------

local function process_frames(frames)
  for _, frame in ipairs(frames) do
    if frame.opcode == OPCODE.TEXT then
      local ok, obj = pcall(json.decode, frame.payload)

      if ok then
        handle_event(obj)
      end
    elseif frame.opcode == OPCODE.PING then
      log.debug('PING received')

      local pong = string.char(0x8A) .. string.char(#frame.payload) .. frame.payload

      job.send(state.jobid, pong)
    elseif frame.opcode == OPCODE.CLOSE then
      log.warn('WebSocket closed')
      job.stop(state.jobid)
    end
  end
end

--------------------------------------------------
-- HTTP handshake + frame reader
--------------------------------------------------

local function on_stdout(_, data)
  local chunk = table.concat(data)

  if not state.handshake_complete then
    state.handshake_buffer = state.handshake_buffer .. chunk

    local pos = state.handshake_buffer:find("\r\n\r\n", 1, true)
      or state.handshake_buffer:find("\n\n", 1, true)

    if not pos then
      return
    end

    state.handshake_complete = true

    local remaining = state.handshake_buffer:sub(pos + 4)

    state.handshake_buffer = ""

    if #remaining > 0 then
      process_frames(parse_frames(remaining))
    end

    return
  end

  process_frames(parse_frames(chunk))
end

--------------------------------------------------
-- connect gateway
--------------------------------------------------

local function connect_gateway()
  state.buffer = ""
  state.handshake_buffer = ""
  state.handshake_complete = false

  state.jobid = job.start({
    "curl",
    "-i",
    "-N",
    "--http1.1",
    "--no-buffer",
    "--tcp-nodelay",
    "-s",
    "-H",
    "Connection: Upgrade",
    "-H",
    "Upgrade: websocket",
    "-H",
    "Sec-WebSocket-Version: 13",
    "-H",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    "wss://gateway.discord.gg/?v=10&encoding=json",
  }, {
    raw = true,

    on_stdout = on_stdout,

    on_exit = function(_, code, signal)
      log.info(
        string.format(
          "Discord gateway disconnected: code=%d signal=%d",
          code,
          signal
        )
      )

      if state.heartbeat then
        state.heartbeat:stop()
        state.heartbeat = nil
      end

      state.jobid = nil

      if state.callback then
        state.reconnect_attempts = state.reconnect_attempts + 1

        local delay = math.min(2 ^ state.reconnect_attempts, 30)

        vim.defer_fn(connect_gateway, delay * 1000)
      end
    end,
  })

  log.debug("Discord gateway connecting jobid=" .. state.jobid)
end

--------------------------------------------------
-- public api
--------------------------------------------------

function M.connect(cb)
  state.callback = cb
  state.reconnect_attempts = 0

  connect_gateway()
end

function M.disconnect()
  state.callback = nil

  if state.heartbeat then
    state.heartbeat:stop()
    state.heartbeat = nil
  end

  if state.jobid then
    job.stop(state.jobid)
  end
end

return M

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

  callback = nil,

  -- WebSocket frame buffer
  buffer = '',

  -- Connection management
  last_heartbeat_ack = 0,
  missed_heartbeats = 0,
  reconnect_attempts = 0,
  is_connecting = false,
  session_id = nil, -- For resume
}

--------------------------------------------------
-- WebSocket frame parser (unchanged)
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
  CONTINUATION = 0x0,
  TEXT = 0x1,
  BINARY = 0x2,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

--------------------------------------------------
-- send gateway payload
--------------------------------------------------

local function send(payload)
  if not state.jobid then
    return
  end

  local data = json.encode(payload)

  local frame = ''
  local len = #data

  frame = frame .. string.char(0x81)

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
-- heartbeat with timeout detection
--------------------------------------------------

local function start_heartbeat(interval)
  if state.heartbeat then
    state.heartbeat:stop()
  end

  state.heartbeat = uv.new_timer()
  state.last_heartbeat_ack = uv.now()
  state.missed_heartbeats = 0

  state.heartbeat:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      -- Check for missed ACKs
      local time_since_ack = uv.now() - state.last_heartbeat_ack
      if time_since_ack > interval * 2 then
        state.missed_heartbeats = state.missed_heartbeats + 1
        log.warn(
          string.format(
            'Missed heartbeat ACK (%d/3)',
            state.missed_heartbeats
          )
        )

        if state.missed_heartbeats >= 3 then
          log.error('Too many missed heartbeats, reconnecting...')
          if state.heartbeat then
            state.heartbeat:stop()
            state.heartbeat = nil
          end
          if state.jobid then
            job.stop(state.jobid)
          end
          return
        end
      end

      log.debug('Sending heartbeat, seq=' .. tostring(state.seq))
      send({
        op = 1,
        d = state.seq,
      })
    end)
  )
end

--------------------------------------------------
-- check mention
--------------------------------------------------

local function is_for_bot(msg)
  if msg.mentions then
    for _, m in ipairs(msg.mentions) do
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
  if data.s and data.s ~= vim.NIL then
    state.seq = data.s
  end

  ------------------------------------------------
  -- HELLO
  ------------------------------------------------

  if data.op == 10 then
    log.debug(
      'Received HELLO, heartbeat_interval=' .. data.d.heartbeat_interval
    )
    start_heartbeat(data.d.heartbeat_interval)

    -- Try to resume if we have a session
    if state.session_id and state.seq then
      log.info('Attempting to resume session: ' .. state.session_id)
      send({
        op = 6,
        d = {
          token = config.config.integrations.discord.token,
          session_id = state.session_id,
          seq = state.seq,
        },
      })
    else
      -- Fresh connection
      send({
        op = 2,
        d = {
          token = config.config.integrations.discord.token,
          intents = 513,
          properties = {
            os = 'linux',
            browser = 'chat.nvim',
            device = 'chat.nvim',
          },
        },
      })
    end

    return
  end

  ------------------------------------------------
  -- HEARTBEAT ACK
  ------------------------------------------------

  if data.op == 11 then
    log.debug('Heartbeat ACK received')
    state.last_heartbeat_ack = uv.now()
    state.missed_heartbeats = 0
    return
  end

  ------------------------------------------------
  -- INVALID SESSION
  ------------------------------------------------

  if data.op == 9 then
    log.warn('Invalid session, can resume: ' .. tostring(data.d))
    if data.d then
      -- Can resume, wait and retry
      vim.defer_fn(function()
        if state.jobid then
          job.stop(state.jobid)
        end
      end, 1000)
    else
      -- Cannot resume, clear session
      state.session_id = nil
      state.seq = nil
      vim.defer_fn(function()
        if state.jobid then
          job.stop(state.jobid)
        end
      end, 1000)
    end
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

  if data.t == 'READY' then
    state.bot_id = data.d.user.id
    state.session_id = data.d.session_id
    state.reconnect_attempts = 0 -- Reset on successful connection

    log.info(
      'Discord gateway ready, bot_id='
        .. state.bot_id
        .. ', session_id='
        .. state.session_id
    )
    return
  end

  ------------------------------------------------
  -- RESUMED
  ------------------------------------------------

  if data.t == 'RESUMED' then
    state.reconnect_attempts = 0
    log.info('Discord gateway resumed successfully')
    return
  end

  ------------------------------------------------
  -- MESSAGE_CREATE
  ------------------------------------------------

  if data.t == 'MESSAGE_CREATE' then
    local msg = data.d

    if msg.author.bot then
      return
    end

    if not is_for_bot(msg) then
      return
    end

    local content = msg.content:gsub('<@!?%d+>', ''):gsub('^%s+', '')

    local out = {
      author = msg.author.username,
      content = content,
      channel_id = msg.channel_id,
      message_id = msg.id,
      reply = msg.referenced_message ~= nil,
    }

    if state.callback then
      vim.schedule(function()
        state.callback(out)
      end)
    end
  end
end

--------------------------------------------------
-- Internal connect function
--------------------------------------------------

local function connect_gateway()
  state.buffer = ''
  state.is_connecting = true

  state.jobid = job.start({
    'curl',
    '-i',
    '-N',
    '--no-buffer',
    '--tcp-nodelay',
    '-s',
    '-H',
    'Upgrade: websocket',
    '-H',
    'Connection: Upgrade',
    '-H',
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
    '-H',
    'Sec-WebSocket-Version: 13',
    'wss://gateway.discord.gg/?v=10&encoding=json',
  }, {
    raw = true,
    on_stdout = function(_, data)
      for _, v in ipairs(data) do
        log.debug(v)
      end
      local frames = parse_frames(table.concat(data))

      for _, frame in ipairs(frames) do
        if frame.opcode == OPCODE.TEXT then
          log.debug('Text frame: ' .. frame.payload)
          local ok, obj = pcall(json.decode, frame.payload)
          if ok and obj then
            handle_event(obj)
          else
            log.error('Failed to decode JSON: ' .. frame.payload)
          end
        elseif frame.opcode == OPCODE.PING then
          log.debug('Received PING, sending PONG')
          local pong_frame = string.char(0x8A, 0) .. frame.payload
          job.send(state.jobid, pong_frame)
        elseif frame.opcode == OPCODE.CLOSE then
          -- Parse close code and reason
          if #frame.payload >= 2 then
            local code = bit.bor(
              bit.lshift(frame.payload:byte(1), 8),
              frame.payload:byte(2)
            )
            local reason = frame.payload:sub(3)
            log.warn(
              string.format(
                'WebSocket close: code=%d, reason=%s',
                code,
                reason
              )
            )
          end
          job.stop(state.jobid)
        end
      end
    end,

    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line and line ~= '' then
          log.error('Discord gateway error: ' .. line)
        end
      end
    end,

    on_exit = function(_, code, signal)
      log.info(
        string.format(
          'Discord gateway disconnected: code=%d, signal=%d',
          code,
          signal
        )
      )

      -- Cleanup
      if state.heartbeat then
        state.heartbeat:stop()
        state.heartbeat = nil
      end
      state.jobid = nil
      state.buffer = ''
      state.is_connecting = false

      -- Auto-reconnect with exponential backoff
      if state.callback and state.reconnect_attempts < 5 then
        state.reconnect_attempts = state.reconnect_attempts + 1
        local delay = math.min(2 ^ state.reconnect_attempts, 30)

        log.info(
          string.format(
            'Reconnecting in %d seconds (attempt %d/5)',
            delay,
            state.reconnect_attempts
          )
        )

        vim.defer_fn(function()
          if state.callback and not state.is_connecting then
            connect_gateway()
          end
        end, delay * 1000)
      elseif state.reconnect_attempts >= 5 then
        log.error(
          'Max reconnection attempts reached. Use M.connect() to retry.'
        )
        state.reconnect_attempts = 0
      end
    end,
  })

  log.debug('Discord gateway connecting, jobid=' .. state.jobid)
end

--------------------------------------------------
-- Public connect function
--------------------------------------------------

function M.connect(callback)
  state.callback = callback
  state.reconnect_attempts = 0 -- Reset on manual connect
  connect_gateway()
end

--------------------------------------------------
-- Disconnect function
--------------------------------------------------

function M.disconnect()
  state.callback = nil -- Prevent reconnection
  state.reconnect_attempts = 5 -- Max out to stop auto-reconnect

  if state.heartbeat then
    state.heartbeat:stop()
    state.heartbeat = nil
  end

  if state.jobid then
    -- Send WebSocket close frame
    local close_frame = string.char(0x88, 0) -- Close frame with no payload
    job.send(state.jobid, close_frame)
    job.stop(state.jobid)
  end

  log.info('Discord gateway disconnected manually')
end

--------------------------------------------------
-- send message (unchanged)
--------------------------------------------------

function M.send_message(content)
  local channel = config.config.integrations.discord.channel_id
  local token = config.config.integrations.discord.token

  if not channel or not token then
    return
  end

  local cmd = {
    'curl',
    '-s',
    'https://discord.com/api/v10/channels/' .. channel .. '/messages',
    '-H',
    'Authorization: Bot ' .. token,
    '-H',
    'Content-Type: application/json',
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local id = job.start(cmd)

  job.send(
    id,
    json.encode({
      content = content,
    })
  )

  job.send(id, nil)
end

--------------------------------------------------
-- reply message (unchanged)
--------------------------------------------------

function M.reply(channel, message_id, text)
  local token = config.config.integrations.discord.token

  local cmd = {
    'curl',
    '-s',
    'https://discord.com/api/v10/channels/' .. channel .. '/messages',
    '-H',
    'Authorization: Bot ' .. token,
    '-H',
    'Content-Type: application/json',
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local id = job.start(cmd)

  job.send(
    id,
    json.encode({

      content = text,

      message_reference = {
        message_id = message_id,
      },
    })
  )

  job.send(id, nil)
end

--------------------------------------------------

function M.receive_messages(cb)
  M.connect(cb)
end

return M

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
}

--------------------------------------------------
-- WebSocket frame parser
--------------------------------------------------

-- Parse WebSocket frame
-- @param data string: raw binary data
-- @return table: parsed frames with {opcode, payload}
local function parse_frames(data)
  state.buffer = state.buffer .. data
  local frames = {}
  
  while #state.buffer >= 2 do
    -- First byte: FIN (1 bit) + RSV (3 bits) + Opcode (4 bits)
    local byte1 = state.buffer:byte(1)
    local fin = bit.band(byte1, 0x80) ~= 0
    local opcode = bit.band(byte1, 0x0F)
    
    -- Second byte: MASK (1 bit) + Payload length (7 bits)
    local byte2 = state.buffer:byte(2)
    local mask = bit.band(byte2, 0x80) ~= 0
    local payload_len = bit.band(byte2, 0x7F)
    
    -- Calculate total frame length
    local header_len = 2
    if payload_len == 126 then
      -- Extended payload length (16 bits)
      if #state.buffer < 4 then
        break -- Need more data
      end
      header_len = 4
      payload_len = bit.bor(
        bit.lshift(state.buffer:byte(3), 8),
        state.buffer:byte(4)
      )
    elseif payload_len == 127 then
      -- Extended payload length (64 bits)
      if #state.buffer < 10 then
        break -- Need more data
      end
      header_len = 10
      -- For simplicity, only handle 32-bit length
      payload_len = bit.bor(
        bit.lshift(state.buffer:byte(7), 24),
        bit.lshift(state.buffer:byte(8), 16),
        bit.lshift(state.buffer:byte(9), 8),
        state.buffer:byte(10)
      )
    end
    
    -- Add mask key length
    if mask then
      header_len = header_len + 4
    end
    
    -- Check if we have complete frame
    if #state.buffer < header_len + payload_len then
      break -- Need more data
    end
    
    -- Extract payload
    local payload
    if mask then
      -- Decode masked payload
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
    
    -- Store frame
    table.insert(frames, {
      opcode = opcode,
      payload = payload,
      fin = fin,
    })
    
    -- Remove processed frame from buffer
    state.buffer = state.buffer:sub(header_len + payload_len + 1)
  end
  
  return frames
end

-- WebSocket opcodes
local OPCODE = {
  CONTINUATION = 0x0,
  TEXT = 0x1,
  BINARY = 0x2,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

--------------------------------------------------
-- send gateway payload (WebSocket text frame)
--------------------------------------------------

local function send(payload)
  if not state.jobid then
    return
  end

  local data = json.encode(payload)
  
  -- Create WebSocket text frame (client to server must be masked)
  local frame = ''
  local len = #data
  
  -- First byte: FIN=1, Opcode=0x1 (text)
  frame = frame .. string.char(0x81)
  
  -- Payload length
  if len <= 125 then
    frame = frame .. string.char(0x80 + len) -- MASK=1
  elseif len <= 65535 then
    frame = frame .. string.char(0x80 + 126) -- MASK=1, extended length
    frame = frame .. string.char(bit.band(bit.rshift(len, 8), 0xFF))
    frame = frame .. string.char(bit.band(len, 0xFF))
  else
    frame = frame .. string.char(0x80 + 127) -- MASK=1, extended length
    -- For simplicity, assume len fits in 32 bits
    frame = frame .. string.char(0, 0, 0, 0)
    frame = frame .. string.char(bit.band(bit.rshift(len, 24), 0xFF))
    frame = frame .. string.char(bit.band(bit.rshift(len, 16), 0xFF))
    frame = frame .. string.char(bit.band(bit.rshift(len, 8), 0xFF))
    frame = frame .. string.char(bit.band(len, 0xFF))
  end
  
  -- Masking key (random 4 bytes)
  local mask_key = string.char(
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255)
  )
  frame = frame .. mask_key
  
  -- Masked payload
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

  state.heartbeat:start(
    interval,
    interval,
    vim.schedule_wrap(function()
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
    log.debug('Received HELLO, heartbeat_interval=' .. data.d.heartbeat_interval)
    start_heartbeat(data.d.heartbeat_interval)

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

    return
  end

  ------------------------------------------------
  -- HEARTBEAT ACK
  ------------------------------------------------

  if data.op == 11 then
    log.debug('Heartbeat ACK received')
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

    log.info('Discord gateway ready, bot_id=' .. state.bot_id)

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
-- connect gateway
--------------------------------------------------

function M.connect(callback)
  state.callback = callback
  state.buffer = '' -- Reset buffer

  state.jobid = job.start({
    'curl',
    '-i',            -- Show HTTP headers
    '-N',            -- No buffering
    '--no-buffer',   -- Disable buffering
    '--tcp-nodelay', -- Reduce latency
    '-s',
    '-H', 'Upgrade: websocket',
    '-H', 'Connection: Upgrade',
    '-H', 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
    '-H', 'Sec-WebSocket-Version: 13',
    'wss://gateway.discord.gg/?v=10&encoding=json',
  }, {
    raw  = true,
    on_stdout = function(_, data)
      -- Parse WebSocket frames
      local frames = parse_frames(table.concat(data))
      
      for _, frame in ipairs(frames) do
        -- Handle different opcodes
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
          -- Send PONG
          local pong_frame = string.char(0x8A, 0) .. frame.payload
          job.send(state.jobid, pong_frame)
        elseif frame.opcode == OPCODE.CLOSE then
          log.info('WebSocket connection closed by server')
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

    on_exit = function(_, code, single)
      log.info(
        string.format(
          'Discord gateway disconnected: code=%d, signal=%d',
          code,
          single
        )
      )

      -- Cleanup
      if state.heartbeat then
        state.heartbeat:stop()
        state.heartbeat = nil
      end
      state.jobid = nil
      state.buffer = ''
    end,
  })

  log.debug('Discord gateway connecting, jobid=' .. state.jobid)
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
-- reply message
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

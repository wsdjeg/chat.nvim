local M = {}

local config = require('chat.config')
local log = require('chat.log')

local job = require('job')

local json = vim.json

-- WebSocket opcodes
local WS_OPCODE_CONTINUATION = 0x0
local WS_OPCODE_TEXT = 0x1
local WS_OPCODE_BINARY = 0x2
local WS_OPCODE_CLOSE = 0x8
local WS_OPCODE_PING = 0x9
local WS_OPCODE_PONG = 0xA

-- State
local ws_state = {
  tcp = nil,
  tls = nil,
  heartbeat_timer = nil,
  session_id = nil,
  sequence = nil,
  callback = nil,
}

-- Generate WebSocket accept key
local function generate_accept_key(key)
  local magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  local combined = key .. magic
  local hash = vim.sha256(combined)
  return vim.base64.encode(hash)
end

-- Encode WebSocket frame
local function encode_frame(payload, opcode, mask)
  local frame = {}
  local len = #payload
  
  -- FIN + opcode
  table.insert(frame, string.char(0x80 | opcode))
  
  -- Payload length
  if len <= 125 then
    table.insert(frame, string.char(len))
  elseif len <= 65535 then
    table.insert(frame, string.char(126))
    table.insert(frame, string.char(math.floor(len / 256)))
    table.insert(frame, string.char(len % 256))
  else
    -- For larger payloads (not typical for Discord messages)
    error("Payload too large")
  end
  
  -- Masking key
  local mask_key = mask or string.char(
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255)
  )
  table.insert(frame, mask_key)
  
  -- Masked payload
  local masked = {}
  for i = 1, #payload do
    local byte = string.byte(payload, i)
    local mask_byte = string.byte(mask_key, ((i - 1) % 4) + 1)
    table.insert(masked, string.char(bit.bxor(byte, mask_byte)))
  end
  table.insert(frame, table.concat(masked))
  
  return table.concat(frame)
end

-- Decode WebSocket frame
local function decode_frame(data)
  if #data < 2 then return nil end
  
  local offset = 1
  local byte1 = string.byte(data, offset)
  local byte2 = string.byte(data, offset + 1)
  
  local fin = bit.band(byte1, 0x80) ~= 0
  local opcode = bit.band(byte1, 0x0F)
  local masked = bit.band(byte2, 0x80) ~= 0
  local payload_len = bit.band(byte2, 0x7F)
  
  offset = offset + 2
  
  -- Extended payload length
  if payload_len == 126 then
    if #data < offset + 1 then return nil end
    payload_len = bit.bor(
      bit.lshift(string.byte(data, offset), 8),
      string.byte(data, offset + 1)
    )
    offset = offset + 2
  elseif payload_len == 127 then
    -- 64-bit length (not needed for Discord)
    return nil, "payload too large"
  end
  
  -- Masking key (server shouldn't mask, but check anyway)
  local mask_key = nil
  if masked then
    if #data < offset + 3 then return nil end
    mask_key = string.sub(data, offset, offset + 3)
    offset = offset + 4
  end
  
  -- Payload
  if #data < offset + payload_len - 1 then return nil end
  local payload = string.sub(data, offset, offset + payload_len - 1)
  
  -- Unmask if needed
  if mask_key then
    local unmasked = {}
    for i = 1, #payload do
      local byte = string.byte(payload, i)
      local mask_byte = string.byte(mask_key, ((i - 1) % 4) + 1)
      table.insert(unmasked, string.char(bit.bxor(byte, mask_byte)))
    end
    payload = table.concat(unmasked)
  end
  
  return {
    fin = fin,
    opcode = opcode,
    payload = payload,
    remaining = string.sub(data, offset + payload_len)
  }
end

-- Send data over WebSocket
local function ws_send(data, opcode)
  opcode = opcode or WS_OPCODE_TEXT
  local frame = encode_frame(data, opcode)
  ws_state.tls:write(frame)
end

-- Handle Discord gateway events
local function handle_gateway_event(payload)
  local data = json.decode(payload)
  if not data then return end
  
  -- Update sequence
  if data.s then
    ws_state.sequence = data.s
  end
  
  -- Handle different opcodes
  if data.op == 10 then -- HELLO
    log.debug("Received HELLO from Discord Gateway")
    
    -- Start heartbeat
    local heartbeat_interval = data.d.heartbeat_interval
    ws_state.heartbeat_timer = vim.uv.new_timer()
    ws_state.heartbeat_timer:start(
      heartbeat_interval,
      heartbeat_interval,
      vim.schedule_wrap(function()
        local heartbeat = json.encode({
          op = 1,
          d = ws_state.sequence
        })
        ws_send(heartbeat)
        log.debug("Sent heartbeat")
      end)
    )
    
    -- Send IDENTIFY
    local identify = json.encode({
      op = 2,
      d = {
        token = config.config.integrations.discord.token,
        intents = 513, -- GUILD_MESSAGES + DIRECT_MESSAGES
        properties = {
          os = vim.uv.os_uname().sysname,
          browser = "chat.nvim",
          device = "chat.nvim"
        }
      }
    })
    ws_send(identify)
    log.debug("Sent IDENTIFY")
    
  elseif data.op == 11 then -- HEARTBEAT_ACK
    log.debug("Received HEARTBEAT_ACK")
    
  elseif data.op == 0 then -- DISPATCH
    if data.t == "READY" then
      ws_state.session_id = data.d.session_id
      log.debug("Discord Gateway ready, session_id: " .. ws_state.session_id)
      
    elseif data.t == "MESSAGE_CREATE" then
      local content = data.d.content
      local author = data.d.author.username
      local channel_id = data.d.channel_id
      
      log.debug(string.format("Message from %s in %s: %s", author, channel_id, content))
      
      -- Call callback if set
      if ws_state.callback then
        vim.schedule(function()
          ws_state.callback({
            author = author,
            content = content,
            channel_id = channel_id,
            timestamp = data.d.timestamp
          })
        end)
      end
    end
  end
end

-- WebSocket handshake
local function perform_handshake()
  local key = vim.base64.encode(tostring(os.time()) .. tostring(math.random()))
  
  local handshake = string.format(
    "GET /?v=10&encoding=json HTTP/1.1\r\n" ..
    "Host: gateway.discord.gg\r\n" ..
    "Upgrade: websocket\r\n" ..
    "Connection: Upgrade\r\n" ..
    "Sec-WebSocket-Key: %s\r\n" ..
    "Sec-WebSocket-Version: 13\r\n" ..
    "\r\n",
    key
  )
  
  ws_state.tls:write(handshake)
  log.debug("Sent WebSocket handshake")
end

-- Read loop
local function start_read_loop()
  local buffer = ""
  
  ws_state.tls:read_start(vim.schedule_wrap(function(err, data)
    if err then
      log.error("Read error: " .. err)
      M.disconnect()
      return
    end
    
    if not data then
      -- Connection closed
      log.debug("Connection closed by server")
      M.disconnect()
      return
    end
    
    buffer = buffer .. data
    
    -- Skip HTTP response headers (for handshake)
    if buffer:find("HTTP/1.1 101") and buffer:find("\r\n\r\n") then
      local headers_end = buffer:find("\r\n\r\n") + 3
      buffer = buffer:sub(headers_end + 1)
      log.debug("WebSocket handshake completed")
    end
    
    -- Process WebSocket frames
    while #buffer > 0 do
      local frame, err = decode_frame(buffer)
      if err then
        log.error("Frame decode error: " .. err)
        break
      end
      
      if not frame then
        -- Need more data
        break
      end
      
      buffer = frame.remaining or ""
      
      -- Handle different opcodes
      if frame.opcode == WS_OPCODE_TEXT then
        handle_gateway_event(frame.payload)
      elseif frame.opcode == WS_OPCODE_PING then
        ws_send(frame.payload, WS_OPCODE_PONG)
        log.debug("Sent PONG")
      elseif frame.opcode == WS_OPCODE_CLOSE then
        log.debug("Received CLOSE frame")
        M.disconnect()
        return
      end
    end
  end))
end

-- Connect to Discord Gateway
function M.connect(callback)
  if not config.config.integrations.discord.token then
    log.error("Discord token not configured")
    return false
  end
  
  ws_state.callback = callback
  
  -- Create TCP connection
  ws_state.tcp = vim.uv.new_tcp()
  
  -- Get address info
  vim.uv.getaddrinfo("gateway.discord.gg", 443, {}, function(err, addresses)
    if err then
      log.error("DNS resolution failed: " .. err)
      return
    end
    
    local addr = addresses[1]
    
    -- Connect
    ws_state.tcp:connect(addr.addr, addr.port, function(connect_err)
      if connect_err then
        log.error("Connection failed: " .. connect_err)
        return
      end
      
      log.debug("TCP connected, starting TLS handshake")
      
      -- Wrap with TLS
      ws_state.tls = vim.uv.new_tls({
        servername = "gateway.discord.gg"
      })
      ws_state.tls:handshake(ws_state.tcp, function(tls_err)
        if tls_err then
          log.error("TLS handshake failed: " .. tls_err)
          return
        end
        
        log.debug("TLS handshake completed")
        
        -- Start reading
        start_read_loop()
        
        -- Send WebSocket handshake
        perform_handshake()
      end)
    end)
  end)
  
  return true
end

-- Disconnect from Discord Gateway
function M.disconnect()
  if ws_state.heartbeat_timer then
    ws_state.heartbeat_timer:stop()
    ws_state.heartbeat_timer:close()
    ws_state.heartbeat_timer = nil
  end
  
  if ws_state.tls then
    ws_state.tls:read_stop()
    ws_state.tls:close()
    ws_state.tls = nil
  end
  
  if ws_state.tcp then
    ws_state.tcp:close()
    ws_state.tcp = nil
  end
  
  ws_state.sequence = nil
  ws_state.session_id = nil
  
  log.debug("Disconnected from Discord Gateway")
end

-- Send message via HTTP API (keep your existing implementation)
function M.send_message(content)
  if
    not config.config.integrations.discord.channel_id
    or not config.config.integrations.discord.token
  then
    log.debug('discord token or channel_id is nil')
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
  
  local jobid = job.start(cmd, {
    on_stdout = function(id, data)
      for _, v in ipairs(data) do log.debug(v) end
    end,
    on_stderr = function(id, data)
      for _, v in ipairs(data) do log.debug(v) end
    end,
    on_exit = function(id, code, single)
      log.debug(string.format('discord job exit code %d, single %d', code, single))
    end,
  })
  
  job.send(jobid, json.encode({
    content = content,
  }))
  job.send(jobid, nil)
end

-- Receive messages (now implemented with WebSocket)
function M.receive_messages(callback)
  return M.connect(callback)
end

return M

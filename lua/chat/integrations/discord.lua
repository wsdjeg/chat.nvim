local M = {}

local config = require("chat.config")
local log = require("chat.log")
local job = require("job")

local uv = vim.uv
local json = vim.json
local bit = bit

--------------------------------------------------
-- websocket
--------------------------------------------------

local WS_TEXT  = 1
local WS_CLOSE = 8
local WS_PING  = 9
local WS_PONG  = 10

--------------------------------------------------
-- state
--------------------------------------------------

local state = {
  tcp = nil,
  tls = nil,

  heartbeat = nil,
  heartbeat_interval = nil,

  seq = nil,
  session_id = nil,
  bot_id = nil,

  zlib = nil,
  inflate = nil,

  callback = nil,
}

--------------------------------------------------
-- proxy
--------------------------------------------------

local function parse_proxy()

  local proxy = os.getenv("https_proxy") or os.getenv("HTTPS_PROXY")
  if not proxy then return end

  local host,port = proxy:match("http://([^:]+):(%d+)")
  if not host then
    host,port = proxy:match("([^:]+):(%d+)")
  end

  if host then
    return host,tonumber(port)
  end
end

--------------------------------------------------
-- websocket encode
--------------------------------------------------

local function ws_encode(payload, opcode)

  opcode = opcode or WS_TEXT

  local len = #payload
  local frame = {}

  table.insert(frame,string.char(bit.bor(0x80,opcode)))

  local maskbit = 0x80

  if len <=125 then
    table.insert(frame,string.char(bit.bor(maskbit,len)))

  elseif len <=65535 then
    table.insert(frame,string.char(bit.bor(maskbit,126)))
    table.insert(frame,string.char(bit.rshift(len,8)))
    table.insert(frame,string.char(bit.band(len,0xff)))
  end

  local mask = string.char(
    math.random(0,255),
    math.random(0,255),
    math.random(0,255),
    math.random(0,255)
  )

  table.insert(frame,mask)

  local out={}

  for i=1,len do
    local b=string.byte(payload,i)
    local m=string.byte(mask,((i-1)%4)+1)
    out[i]=string.char(bit.bxor(b,m))
  end

  table.insert(frame,table.concat(out))

  return table.concat(frame)
end

--------------------------------------------------
-- websocket decode
--------------------------------------------------

local function ws_decode(data)

  if #data<2 then return end

  local b1=string.byte(data,1)
  local b2=string.byte(data,2)

  local opcode=bit.band(b1,0x0f)
  local len=bit.band(b2,0x7f)

  local offset=3

  if len==126 then
    if #data<4 then return end

    len=bit.bor(
      bit.lshift(string.byte(data,3),8),
      string.byte(data,4)
    )

    offset=5
  end

  if #data<offset+len-1 then
    return
  end

  local payload=data:sub(offset,offset+len-1)

  return{
    opcode=opcode,
    payload=payload,
    rest=data:sub(offset+len)
  }
end

--------------------------------------------------
-- send
--------------------------------------------------

local function ws_send(data,opcode)
  state.tls:write(ws_encode(data,opcode))
end

--------------------------------------------------
-- heartbeat
--------------------------------------------------

local function start_heartbeat()

  if state.heartbeat then
    state.heartbeat:stop()
  end

  state.heartbeat=uv.new_timer()

  state.heartbeat:start(
    state.heartbeat_interval,
    state.heartbeat_interval,
    function()

      ws_send(json.encode({
        op=1,
        d=state.seq
      }))

    end
  )

end

--------------------------------------------------
-- mention detection
--------------------------------------------------

local function is_for_bot(msg)

  if msg.mentions then
    for _,m in ipairs(msg.mentions) do
      if m.id==state.bot_id then
        return true
      end
    end
  end

  if msg.referenced_message then
    local a=msg.referenced_message.author
    if a and a.id==state.bot_id then
      return true
    end
  end

  return false
end

--------------------------------------------------
-- gateway event
--------------------------------------------------

local function handle_gateway(payload)

  local ok,data=pcall(json.decode,payload)
  if not ok then return end

  if data.s then
    state.seq=data.s
  end

  ------------------------------------------------
  -- HELLO
  ------------------------------------------------

  if data.op==10 then

    state.heartbeat_interval=data.d.heartbeat_interval
    start_heartbeat()

    local payload

    if state.session_id then

      payload={
        op=6,
        d={
          token=config.config.integrations.discord.token,
          session_id=state.session_id,
          seq=state.seq
        }
      }

    else

      payload={
        op=2,
        d={
          token=config.config.integrations.discord.token,
          intents=513,
          properties={
            os="linux",
            browser="chat.nvim",
            device="chat.nvim"
          }
        }
      }

    end

    ws_send(json.encode(payload))

    return
  end

  ------------------------------------------------
  -- heartbeat ack
  ------------------------------------------------

  if data.op==11 then
    return
  end

  ------------------------------------------------
  -- dispatch
  ------------------------------------------------

  if data.op~=0 then return end

  if data.t=="READY" then

    state.session_id=data.d.session_id
    state.bot_id=data.d.user.id

    log.debug("discord ready "..state.bot_id)
    return
  end

  ------------------------------------------------
  -- message
  ------------------------------------------------

  if data.t=="MESSAGE_CREATE" then

    local msg=data.d

    if msg.author.bot then return end
    if not is_for_bot(msg) then return end

    local content=msg.content
      :gsub("<@!?%d+>","")
      :gsub("^%s+","")

    local out={
      author=msg.author.username,
      content=content,
      channel_id=msg.channel_id,
      message_id=msg.id,
      reply=msg.referenced_message~=nil
    }

    if state.callback then
      vim.schedule(function()
        state.callback(out)
      end)
    end

  end

end

--------------------------------------------------
-- inflate zlib
--------------------------------------------------

local function inflate(data)

  if not state.inflate then
    local ok,zlib=pcall(require,"zlib")
    if not ok then
      return data
    end

    state.inflate=zlib.inflate()
  end

  local ok,res=pcall(state.inflate,data)

  if ok then
    return res
  end
end

--------------------------------------------------
-- read loop
--------------------------------------------------

local function start_read()

  local buffer=""

  state.tls:read_start(function(err,data)

    if err then
      log.error(err)
      return
    end

    if not data then
      return
    end

    buffer=buffer..data

    local header=buffer:find("\r\n\r\n")

    if header then
      buffer=buffer:sub(header+4)
    end

    while true do

      local frame=ws_decode(buffer)
      if not frame then break end

      buffer=frame.rest or ""

      if frame.opcode==WS_TEXT then

        local payload=inflate(frame.payload) or frame.payload

        handle_gateway(payload)

      elseif frame.opcode==WS_PING then
        ws_send(frame.payload,WS_PONG)

      elseif frame.opcode==WS_CLOSE then
        return
      end

    end

  end)

end

--------------------------------------------------
-- websocket handshake
--------------------------------------------------

local function websocket_handshake()

  local key=vim.base64.encode(tostring(os.time()))

  local req=table.concat({

    "GET /?v=10&encoding=json&compress=zlib-stream HTTP/1.1",
    "Host: gateway.discord.gg",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Key: "..key,
    "User-Agent: chat.nvim",
    "\r\n"

  },"\r\n")

  state.tls:write(req)

end

--------------------------------------------------
-- connect
--------------------------------------------------

function M.connect(callback)

  state.callback=callback

  local proxy_host,proxy_port=parse_proxy()

  local host=proxy_host or "gateway.discord.gg"
  local port=proxy_port or 443

  state.tcp=uv.new_tcp()

  state.tcp:connect(host,port,function(err)

    if err then
      log.error(err)
      return
    end

    ------------------------------------------------
    -- proxy connect
    ------------------------------------------------

    if proxy_host then

      local req=table.concat({
        "CONNECT gateway.discord.gg:443 HTTP/1.1",
        "Host: gateway.discord.gg",
        "\r\n"
      },"\r\n")

      state.tcp:write(req)

      state.tcp:read_start(function(_,data)

        if data and data:find("200") then

          state.tcp:read_stop()

          state.tls=uv.new_tls({
            servername="gateway.discord.gg"
          })

          state.tls:handshake(state.tcp,function()

            start_read()
            websocket_handshake()

          end)

        end

      end)

    else

      state.tls=uv.new_tls({
        servername="gateway.discord.gg"
      })

      state.tls:handshake(state.tcp,function()

        start_read()
        websocket_handshake()

      end)

    end

  end)

end

--------------------------------------------------
-- send message
--------------------------------------------------

function M.send_message(content)

  local channel=config.config.integrations.discord.channel_id
  local token=config.config.integrations.discord.token

  local cmd={
    "curl",
    "-s",
    "https://discord.com/api/v10/channels/"..channel.."/messages",
    "-H","Authorization: Bot "..token,
    "-H","Content-Type: application/json",
    "-X","POST",
    "-d","@-"
  }

  local id=job.start(cmd)

  job.send(id,json.encode({
    content=content
  }))

  job.send(id,nil)

end

--------------------------------------------------

function M.receive_messages(cb)
  M.connect(cb)
end

return M

-- lua/chat/integrations/weixin/types.lua
-- WeChat integration type definitions and constants

local M = {}

-- Message types (proto: MessageType)
M.MessageType = {
  NONE = 0,
  USER = 1,
  BOT = 2,
}

-- Message item types (proto: MessageItemType)
M.MessageItemType = {
  NONE = 0,
  TEXT = 1,
  IMAGE = 2,
  VOICE = 3,
  FILE = 4,
  VIDEO = 5,
}

-- Message states (proto: MessageState)
M.MessageState = {
  NEW = 0,
  GENERATING = 1,
  FINISH = 2,
}

-- Typing status
M.TypingStatus = {
  TYPING = 1,
  CANCEL = 2,
}

-- Upload media types
M.UploadMediaType = {
  IMAGE = 1,
  VIDEO = 2,
  FILE = 3,
  VOICE = 4,
}

-- Error codes
M.ErrorCode = {
  SUCCESS = 0,
  SESSION_EXPIRED = -14,
  INVALID_TOKEN = -5,
  RATE_LIMIT = -10,
}

-- Default timeouts (ms)
M.Timeout = {
  LONG_POLL = 35000, -- Long-poll timeout
  API_REQUEST = 15000, -- Regular API timeout
  CONFIG_REQUEST = 10000, -- Config/typing timeout
}

-- Message limits
M.Limits = {
  MAX_MESSAGE_LENGTH = 2048, -- WeChat message length limit
  MAX_QUEUE_SIZE = 100, -- Max messages in queue
  MAX_PROCESSED_CACHE = 100, -- Max processed message IDs to cache
}

return M

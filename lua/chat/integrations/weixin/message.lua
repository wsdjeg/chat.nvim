-- Message parsing and handling

local M = {}

local log = require('chat.log')
local Types = require('chat.integrations.weixin.types')

--------------------------------------------------
-- Parse message item
--------------------------------------------------
function M.parse_item(item)
  if not item then
    return nil
  end

  local msg_type = item.type

  if msg_type == Types.MessageItemType.TEXT then
    return {
      type = 'text',
      text = item.text_item and item.text_item.text or '',
    }
  elseif msg_type == Types.MessageItemType.IMAGE then
    return {
      type = 'image',
      aes_key = item.image_item and item.image_item.aes_key,
      encrypt_query_param = item.image_item and item.image_item.encrypt_query_param,
    }
  elseif msg_type == Types.MessageItemType.VOICE then
    return {
      type = 'voice',
      aes_key = item.voice_item and item.voice_item.aes_key,
      encrypt_query_param = item.voice_item and item.voice_item.encrypt_query_param,
      text = item.voice_item and item.voice_item.text, -- Voice-to-text
    }
  elseif msg_type == Types.MessageItemType.FILE then
    return {
      type = 'file',
      aes_key = item.file_item and item.file_item.aes_key,
      encrypt_query_param = item.file_item and item.file_item.encrypt_query_param,
    }
  elseif msg_type == Types.MessageItemType.VIDEO then
    return {
      type = 'video',
      aes_key = item.video_item and item.video_item.aes_key,
      encrypt_query_param = item.video_item and item.video_item.encrypt_query_param,
    }
  end

  return nil
end

--------------------------------------------------
-- Parse WeixinMessage (proto: WeixinMessage)
--------------------------------------------------
function M.parse(msg)
  if not msg then
    return nil
  end

  local parsed = {
    seq = msg.seq,
    message_id = msg.message_id,
    from_user_id = msg.from_user_id,
    to_user_id = msg.to_user_id,
    create_time_ms = msg.create_time_ms,
    session_id = msg.session_id,
    message_type = msg.message_type,
    message_state = msg.message_state,
    context_token = msg.context_token,
    items = {},
  }

  -- Parse item_list
  if msg.item_list then
    for _, item in ipairs(msg.item_list) do
      local parsed_item = M.parse_item(item)
      if parsed_item then
        table.insert(parsed.items, parsed_item)
      end
    end
  end

  return parsed
end

--------------------------------------------------
-- Extract text from parsed message
--------------------------------------------------
function M.get_text(parsed_msg)
  if not parsed_msg or not parsed_msg.items then
    return ''
  end

  local text = ''
  for _, item in ipairs(parsed_msg.items) do
    if item.type == 'text' then
      text = text .. item.text
    elseif item.type == 'voice' and item.text then
      -- Voice-to-text
      text = text .. item.text
    end
  end

  return text
end

--------------------------------------------------
-- Check if message should be processed
-- Only process NEW messages from USER
--------------------------------------------------
function M.should_process(parsed_msg)
  if not parsed_msg then
    return false
  end

  -- Only process USER messages
  if parsed_msg.message_type ~= Types.MessageType.USER then
    return false
  end

  -- Only process NEW messages
  if parsed_msg.message_state ~= Types.MessageState.NEW then
    return false
  end

  return true
end

--------------------------------------------------
-- Process inbound messages and extract text
--------------------------------------------------
function M.extract_inbound(msgs, context_tokens)
  if not msgs or #msgs == 0 then
    return {}
  end

  local inbound = {}

  for _, msg in ipairs(msgs) do
    local parsed = M.parse(msg)

    if M.should_process(parsed) then
      -- Store context_token for this user
      if parsed.from_user_id and parsed.context_token then
        context_tokens[parsed.from_user_id] = parsed.context_token
      end

      -- Extract text
      local text = M.get_text(parsed)
      if text and text ~= '' then
        table.insert(inbound, {
          user_id = parsed.from_user_id,
          content = text,
          message_id = parsed.message_id,
          context_token = parsed.context_token,
        })
      end
    end
  end

  return inbound
end

return M


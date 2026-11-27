-- Message parsing and handling

local M = {}

local log = require('chat.log')
local Types = require('chat.integrations.weixin.types')

--- Placeholder used when a VOICE item carries no server-side transcript.
---
--- WeChat only fills `voice_item.text` when its own ASR succeeded. When it
--- fails (or the sender disabled voice-to-text) `text` is an empty string and
--- the item used to be dropped silently by `get_text()`, so the bot never
--- answered a voice message at all. Other integrations use the same
--- convention (`[voice]` for telegram, `[media]`/`[audio]` for lark), so the
--- model at least knows something was sent.
local VOICE_PLACEHOLDER = '[voice]'

--------------------------------------------------
-- Resolve the CDN media reference of an item
--------------------------------------------------
--- Media lives in a nested `media` object for every item type:
---   { "voice_item": { "media": { "encrypt_query_param": ..., "aes_key": ... } } }
--- Older payloads (and the original unit tests) put the fields directly on
--- the sub-item, so both shapes are accepted.
--- @param sub table|nil the `*_item` sub-structure
--- @return table media reference (empty table when absent)
local function media_of(sub)
  if not sub then
    return {}
  end
  local media = sub.media
  if type(media) == 'table' then
    return media
  end
  return sub
end

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
    local image = item.image_item or {}
    local media = media_of(image)
    return {
      type = 'image',
      -- `aeskey` is the 32-char hex form used by some inbound images and
      -- takes precedence over the media reference when both are present.
      aes_key = image.aeskey or media.aes_key,
      encrypt_query_param = media.encrypt_query_param,
    }
  elseif msg_type == Types.MessageItemType.VOICE then
    local voice = item.voice_item or {}
    local media = media_of(voice)
    local text = voice.text
    return {
      type = 'voice',
      aes_key = media.aes_key,
      encrypt_query_param = media.encrypt_query_param,
      -- Plain download URL, usable without the CDN base URL being rebuilt.
      url = media.full_url,
      -- Voice-to-text: empty when WeChat's own ASR did not produce one.
      text = text,
      encode_type = voice.encode_type,
      sample_rate = voice.sample_rate,
      playtime = voice.playtime,
    }
  elseif msg_type == Types.MessageItemType.FILE then
    local file = item.file_item or {}
    local media = media_of(file)
    return {
      type = 'file',
      aes_key = media.aes_key,
      encrypt_query_param = media.encrypt_query_param,
      url = media.full_url,
      name = file.file_name,
    }
  elseif msg_type == Types.MessageItemType.VIDEO then
    local video = item.video_item or {}
    local media = media_of(video)
    return {
      type = 'video',
      aes_key = media.aes_key,
      encrypt_query_param = media.encrypt_query_param,
      url = media.full_url,
      playtime = video.play_length,
    }
  end

  return nil
end

--------------------------------------------------
-- Parse WeixinMessage (proto: WeixinMessage)
--------------------------------------------------
function M.parse(msg)
  local ok, json_str = pcall(vim.json.encode, msg)
  if ok then
    log.debug(string.format('[WeChat] parse raw message: %s', json_str))
  end
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
---@param parsed_msg table parsed message
---@return string text to hand to the model, '' when nothing is readable
function M.get_text(parsed_msg)
  if not parsed_msg or not parsed_msg.items then
    return ''
  end

  local text = ''
  for _, item in ipairs(parsed_msg.items) do
    if item.type == 'text' then
      text = text .. (item.text or '')
    elseif item.type == 'voice' then
      -- Voice-to-text. When WeChat did not transcribe the audio, fall back to
      -- a placeholder instead of contributing nothing: an empty string makes
      -- extract_inbound() drop the message, so a voice note got no reply.
      if item.text and item.text ~= '' then
        text = text .. item.text
      else
        log.debug(
          string.format(
            '[Weixin] Voice item without transcript (encode_type=%s, '
              .. 'playtime=%s), using placeholder',
            tostring(item.encode_type),
            tostring(item.playtime)
          )
        )
        text = text .. VOICE_PLACEHOLDER
      end
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
    log.warn('[WeChat] should_process: parsed_msg is nil')
    return false
  end

  log.debug(
    string.format(
      '[WeChat] should_process: message_type=%s (expect USER=%s), message_state=%s (expect NEW=%s)',
      parsed_msg.message_type,
      Types.MessageType.USER,
      parsed_msg.message_state,
      Types.MessageState.NEW
    )
  )

  -- Only process USER messages
  if parsed_msg.message_type ~= Types.MessageType.USER then
    log.debug(
      string.format(
        '[WeChat] should_process: skip non-USER message, type=%s',
        parsed_msg.message_type
      )
    )
    return false
  end

  -- Process USER messages (regardless of state for now)
  -- NOTE: Weixin API returns FINISH state for regular messages
  log.debug('[WeChat] should_process: message accepted')
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
        log.debug(
          string.format(
            '[Weixin] Stored context_token for user %s: %s',
            parsed.from_user_id,
            parsed.context_token:sub(1, 20) .. '...'
          )
        )
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



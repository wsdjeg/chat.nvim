local M = {}

local config = require('chat.config')
local tools = require('chat.tools')
local sessions = require('chat.sessions')

function M.generate_message(message, session)
  if message.role == 'assistant' and message.tool_calls then
    local msg = {}
    if message.reasoning_content then
      table.insert(
        msg,
        '['
          .. os.date(config.config.strftime, message.created)
          .. '] 🤖 Bot:'
          .. ((message.reasoning_content and ' thinking ...') or '')
      )
      table.insert(msg, '')
    end
    if message.reasoning_content then
      for _, line in ipairs(vim.split(message.reasoning_content, '\n')) do
        table.insert(msg, '> ' .. line)
      end
      table.insert(msg, '')
    end
    if message.content then
      for _, line in ipairs(vim.split(message.content, '\n')) do
        table.insert(msg, line)
      end
      table.insert(msg, '')
    end
    for i = 1, #message.tool_calls do
      table.insert(
        msg,
        string.format(
          '[%s] 🤖 Bot: 🔧 Executing tool: %s',
          os.date(config.config.strftime, message.created),
          tools.info(
            message.tool_calls[i],
            { cwd = sessions.getcwd(session) }
          )
        )
      )
      table.insert(msg, '')
    end

    return msg
  elseif message.role == 'assistant' then
    local msg = {
      '['
        .. os.date(config.config.strftime, message.created)
        .. '] 🤖 Bot:'
        .. ((message.reasoning_content and ' thinking ...') or ''),
      '',
    }
    if message.reasoning_content and #message.reasoning_content > 0 then
      for _, line in ipairs(vim.split(message.reasoning_content, '\n')) do
        table.insert(msg, '> ' .. line)
      end
      table.insert(msg, '')
    end
    if message.content then
      for _, line in ipairs(vim.split(message.content, '\n')) do
        table.insert(msg, line)
      end
      table.insert(msg, '')
    end
    return msg
  elseif message.role == 'user' then
    local content = vim.split(message.content, '\n')
    local msg = {
      '['
        .. os.date(config.config.strftime, message.created)
        .. '] 👤 You: '
        .. content[1],
    }
    if #content > 1 then
      for i = 2, #content do
        table.insert(msg, content[i])
      end
    end
    table.insert(msg, '')
    return msg
  elseif message.role == 'tool' then
    if message.tool_call_state and message.tool_call_state.error then
      local msg = vim.split(
        string.format(
          '[%s] ❌ : Tool Error: %s',
          os.date(config.config.strftime, message.created),
          message.tool_call_state.error
        ),
        '\n'
      )
      table.insert(msg, '')
      return msg
    else
      return {
        string.format(
          '[%s] 🤖 Bot: ✅ Tool execution complete: %s',
          os.date(config.config.strftime, message.created),
          (message.tool_call_state and message.tool_call_state.name) or ''
        ),
        '',
      }
    end
  elseif message.content and message.role ~= 'tool' then
    return vim.split(message.content, '\n')
  elseif message.on_complete then
    local complete_str = ' ✅ Completed'
    if message.usage then
      complete_str = complete_str
        .. string.format(
          ' • Tokens: %d (%d↑/%d↓)',
          message.usage.total_tokens,
          message.usage.prompt_tokens,
          message.usage.completion_tokens
        )

      if
        message.usage.prompt_tokens_details
        and message.usage.prompt_tokens_details ~= vim.NIL
        and message.usage.prompt_tokens_details.cached_tokens
        and message.usage.prompt_tokens_details.cached_tokens > 0
      then
        local cached = message.usage.prompt_tokens_details.cached_tokens
        local percent = math.floor(cached / message.usage.prompt_tokens * 100)
        complete_str = complete_str .. string.format(' 💾 %d%%', percent)
      end
    end
    return {
      '['
        .. os.date(config.config.strftime, message.created)
        .. '] 🤖 Bot:'
        .. complete_str,
      '',
    }
  elseif message.error then
    local msg = vim.split(
      string.format(
        '[%s] ❌ : %s',
        os.date(config.config.strftime, message.created),
        message.error
      ),
      '\n'
    )
    table.insert(msg, '')
    return msg
  else
    return {}
  end
end

function M.generate_buffer(messages, session)
  local lines = {}
  for _, m in ipairs(messages) do
    for _, l in ipairs(M.generate_message(m, session)) do
      table.insert(lines, l)
    end
  end
  return lines
end

return M

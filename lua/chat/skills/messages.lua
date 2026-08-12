-- lua/chat/skills/messages.lua
-- /messages - Capture current Neovim :messages output and ask the LLM
-- to diagnose and fix any errors/warnings.
--
-- Usage:
--   /messages

local log = require('chat.log')

return {
  name = 'messages',
  description = 'Capture Neovim :messages and ask LLM to fix errors',
  handler = function(_, _)
    local output = vim.fn.execute('messages')

    if not output or vim.trim(output) == '' then
      log.notify('No messages in Neovim :messages')
      return 'Neovim :messages is empty — no errors or warnings to fix.'
    end

    local content = table.concat({
      '以下是通过 `:messages` 获取的当前 Neovim 实例的消息列表，',
      '其中可能包含错误（Error）、警告（Warning）或提示（Info）信息。',
      '请逐一排查这些消息，找出根本原因并修复。',
      '',
      '```',
      output,
      '```',
    }, '\n')

    return {
      content = content,
      role = 'user',
      request = true,
    }
  end,
}


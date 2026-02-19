local M = {}

local config = require('chat.config')
local util = require('chat.util')
local sessions = require('chat.sessions')

---@class ChatToolsSetPromptAction
---@field filepath string  Path to prompt file

---@param action ChatToolsSetPromptAction
---@param ctx ChatToolContext
function M.set_prompt(action, ctx)
  local filepath = util.resolve(action.filepath, ctx.cwd)
  
  if not filepath then
    return {
      error = 'Prompt file path is required.'
    }
  end
  
  if vim.fn.filereadable(filepath) == 0 then
    return {
      error = string.format('File is not readable: %s', filepath)
    }
  end
  
  -- Check if file is in allowed path
  local is_allowed_path = false
  
  if type(config.config.allowed_path) == 'table' then
    for _, v in ipairs(config.config.allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(filepath, v) then
          is_allowed_path = true
          break
        end
      end
    end
  elseif
    type(config.config.allowed_path) == 'string'
    and #config.config.allowed_path > 0
  then
    is_allowed_path = vim.startswith(filepath, config.config.allowed_path)
  end
  
  if not is_allowed_path then
    return {
      error = string.format('File path %s is not in allowed paths.', filepath)
    }
  end
  
  -- Read file content
  local ok, content = pcall(vim.fn.readfile, filepath)
  if not ok then
    return {
      error = string.format('Failed to read file: %s', content)
    }
  end
  
  local prompt = table.concat(content, '\n')
  
  -- Update current session's system prompt
  local success = sessions.set_session_prompt(ctx.session, prompt)
  
  if success then
    return {
      content = string.format('Set session prompt from %s', filepath)
    }
  else
    return {
      error = 'Failed to set session prompt.'
    }
  end
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'set_prompt',
      description = [[Read a prompt file and set it as the current session's system prompt.

Examples:
- @set_prompt ./AGENTS.md
- @set_prompt ./prompts/code_review.txt
- @set_prompt ~/.config/chat.nvim/default_prompt.md

This tool reads the specified file and updates the current session's system prompt
with its content. The file must be within the allowed_path configured in chat.nvim.]],
      parameters = {
        type = 'object',
        properties = {
          filepath = {
            type = 'string',
            description = 'Path to prompt file',
          },
        },
        required = { 'filepath' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    return string.format('set_prompt %s', util.resolve(arguments.filepath, ctx.cwd))
  else
    return 'set_prompt'
  end
end

return M


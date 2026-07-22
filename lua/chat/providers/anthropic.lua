local M = {}

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

-- Use Anthropic protocol
M.protocol = 'anthropic'

function M.available_models()
  return {
    'claude-3-5-sonnet-20241022',
    'claude-3-5-haiku-20241022',
    'claude-3-opus-20240229',
    'claude-3-sonnet-20240229',
    'claude-3-haiku-20240307',
  }
end

function M.request(opt)
  local system_prompt, anthropic_messages = require('chat.protocol.anthropic').convert_message(opt.messages)

  -- Build request body
  local body = {
    model = sessions.get_session_model(opt.session),
    messages = anthropic_messages,
    max_tokens = 4096,
    stream = true,
  }

  if system_prompt then
    body.system = system_prompt
  end

  -- Add tools if available
  local tools = require('chat.tools').available_tools()
  if tools and #tools > 0 then
    body.tools = M._convert_tools(tools)
  end

  local body_json = vim.json.encode(body)

  local cmd = curl.build_request({
    url = 'https://api.anthropic.com/v1/messages',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
      'x-api-key: ' .. config.config.api_key.anthropic,
      'anthropic-version: 2023-06-01',
    },
    body = body_json,
  })

  local jobid = job.start(cmd, {
    on_stdout = opt.on_stdout,
    on_stderr = opt.on_stderr,
    on_exit = opt.on_exit,
  })
  job.send(jobid, body_json)
  sessions.set_session_jobid(opt.session, jobid)

  return jobid
end

-- Convert OpenAI tools format to Anthropic format
function M._convert_tools(tools)
  local anthropic_tools = {}
  for _, tool in ipairs(tools) do
    if tool.type == 'function' then
      table.insert(anthropic_tools, {
        name = tool['function'].name,
        description = tool['function'].description,
        input_schema = tool['function'].parameters,
      })
    end
  end
  return anthropic_tools
end

return M


local M = {}

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  return {
    'glm-5',
    'minimax-m2.5',
    'kimi-k2.5',
    'qwen3.5-plus',
    'deepseek-v3_2',
  }
end

function M.request(opt)
  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    stream = true,
    chat_template_kwargs = {
      enable_thinking = true,
    },
    stream_options = { include_usage = true },
    tools = require('chat.tools').request_tools(opt.session),
  })

  local cmd = curl.build_request({
    url = 'https://maas-api.ai-yuanjing.com/openapi/compatible-mode/v1/chat/completions',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. config.config.api_key.yuanjing,
    },
    stdin_body = true,
  })

  local jobid = job.start(cmd, {
    on_stdout = opt.on_stdout,
    on_stderr = opt.on_stderr,
    on_exit = opt.on_exit,
  })
  job.send(jobid, body)
  job.send(jobid, nil)
  sessions.set_session_jobid(opt.session, jobid)

  return jobid
end

return M


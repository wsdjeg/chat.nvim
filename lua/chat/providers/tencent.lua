local M = {}

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  return {
    'hunyuan-lite',
    'hunyuan-pro',
    'hunyuan-2.0-thinking-20251109',
    'hunyuan-2.0-instruct-20251111',
    'hunyuan-t1-latest',
    'hunyuan-a13b',
    'hunyuan-turbos-latest',
    'hunyuan-translation',
    'hunyuan-translation-lite',
    'hunyuan-large-role-latest',
  }
end

function M.request(opt)
  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    enable_thinking = true,
    stream = true,
    stream_options = { include_usage = true },
    tools = require('chat.tools').available_tools(),
  })

  local cmd = curl.build_request({
    url = 'https://api.hunyuan.cloud.tencent.com/v1/chat/completions',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. config.config.api_key.tencent,
    },
    body = body,
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


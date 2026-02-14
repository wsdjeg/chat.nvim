local M = {}

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  return {
    'doubao-seed-2-0-code-preview-260215',
    'doubao-seed-2-0-mini-260215',
    'doubao-seed-2-0-lite-260215',
    'doubao-seed-2-0-pro-260215',
    'deepseek-v3-2-251201',
    'glm-4-7-251222',
  }
end

function M.request(opt)
  local cmd = {
    'curl',
    '-s',
    'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. config.config.api_key.volcengine,
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    enable_thinking = true,
    stream = true,
    stream_options = { include_usage = true },
    tools = require('chat.tools').available_tools(),
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

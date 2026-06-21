local M = {}

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

local model_max_tokens = {
  ['deepseek-v4-flash'] = 384 * 1024,
  ['deepseek-v4-pro'] = 384 * 1024,
  ['minimax-m2.7'] = 128 * 1024,
  ['minimax-m3'] = 128 * 1024,
  ['kimi-k2.6'] = 32 * 1024,
  ['glm-5.2'] = 128000,
}

local function get_max_tokens(model)
  return model_max_tokens[model] or 4096
end

function M.available_models()
  return {
    'glm-5.2',
    'doubao-seed-code',
    'doubao-seed-2.0-code',
    'doubao-seed-2.0-pro',
    'doubao-seed-2.0-lite',
    'minimax-m2.7',
    'kimi-k2.6',
    'deepseek-v4-pro',
    'deepseek-v4-flash',
    'minimax-m3',
  }
end

function M.request(opt)
  local cmd = {
    'curl',
    '-s',
    'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. config.config.api_key.volcengine_coding_plan,
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local model = sessions.get_session_model(opt.session)

  local body = vim.json.encode({
    model = model,
    messages = opt.messages,
    thinking = {
      type = 'enabled',
    },
    stream = true,
    tool_stream = true,
    max_tokens = get_max_tokens(model),
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


local M = {}

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

local model_max_tokens = {
  ['deepseek-v4-flash'] = 384 * 1024,
  ['deepseek-v4-pro'] = 384 * 1024,
  ['deepseek-v4.1-flash'] = 384 * 1024,
  ['minimax-m3'] = 128 * 1024,
  ['minimax-m2.7'] = 128 * 1024,
  ['kimi-k2.7-code'] = 32 * 1024,
  ['kimi-k2.8-preview'] = 32 * 1024,
  ['kimi-k3'] = 32 * 1024,
  ['kimi-k2.6'] = 32 * 1024,
  ['glm-5.3'] = 128000,
  ['glm-latest'] = 128000,
  ['glm-5.3-flash'] = 128000,
  ['glm-5.2'] = 128000,
}

local function get_max_tokens(model)
  return model_max_tokens[model] or 4096
end

function M.available_models()
  return {
    'doubao-seed-evolving',
    'doubao-seed-2.1-pro',
    'doubao-seed-2.1-lite',
    'doubao-seed-2.0-mini',
    'minimax-m3',
    'minimax-m2.7',
    'glm-5.3',
    'glm-latest',
    'glm-5.3-flash',
    'glm-5.2',
    'deepseek-v4.1-flash',
    'deepseek-v4-flash',
    'deepseek-v4-pro',
    'kimi-k2.7-code',
    'kimi-k2.8-preview',
    'kimi-k3',
    'kimi-k2.6',
  }
end

function M.request(opt)
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
    tools = require('chat.tools').request_tools(opt.session),
  })

  local cmd = curl.build_request({
    url = 'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
    method = 'POST',
    no_buffer = true,
    tcp_nodelay = true,
    connect_timeout = 10,
    max_time = 300,
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. config.config.api_key.volcengine_coding_plan,
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


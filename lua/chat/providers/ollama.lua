local M = {}

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

-- Use OpenAI protocol (Ollama is compatible)
-- M.protocol = 'openai'  -- default, no need to specify

-- Default Ollama API endpoint
local function get_ollama_host()
  return config.config.ollama_host or 'http://localhost:11434'
end

function M.available_models()
  -- Fetch available models from Ollama
  local cmd = {
    'curl',
    '-s',
    get_ollama_host() .. '/api/tags',
  }

  local models = {}
  local result = vim.system(cmd, { text = true }):wait()

  if result.code == 0 then
    local ok, data = pcall(vim.json.decode, result.stdout)
    if ok and data.models then
      for _, model in ipairs(data.models) do
        table.insert(models, model.name)
      end
    end
  end

  return models
end

function M.request(opt)
  -- Use OpenAI-compatible endpoint: /v1/chat/completions
  local cmd = {
    'curl',
    '-s',
    get_ollama_host() .. '/v1/chat/completions', -- OpenAI compatible endpoint
    '-H',
    'Content-Type: application/json',
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
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

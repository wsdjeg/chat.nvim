local M = {}

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  return {
    'MiMo-V2.5-Pro',
    'MiMo-V2.5',
    'MiMo-V2.5-TTS-VoiceClone',
    'MiMo-V2.5-TTS-VoiceDesign',
    'MiMo-V2.5-TTS',
    'MiMo-V2-Pro',
    'MiMo-V2-Omni',
    'MiMo-V2-TTS',
  }
end

function M.request(opt)
  local cmd = {
    'curl',
    '-s',
    'https://token-plan-sgp.xiaomimimo.com/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. config.config.api_key.xiaomi_token_plan,
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    thinking = {
      type = 'enabled',
    },
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

local M = {}

local available_models = {}

local job = require('job')
local sessions = require('chat.sessions')

function M.available_models()
  if #available_models == 0 then
    local config = require('chat.config')
    local cmd = {
      'curl',
      '-s',
      '-H',
      'Content-Type: application/json',
      '-H',
      'Authorization: Bearer ' .. config.config.api_key.moonshot,
      'https://api.moonshot.cn/v1/models',
    }
    local systemObj = vim.system(cmd):wait()
    if systemObj.code == 0 then
      local ok, result = pcall(vim.json.decode, systemObj.stdout)
      if ok then
        for _, model in ipairs(result) do
          table.insert(available_models, model.id)
        end
      end
    end
  end
  return available_models
end

function M.request(requestObj)
  local cmd = {
    'curl',
    '-s',
    'https://api.moonshot.cn/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. requestObj.api_key,
    '-X',
    'POST',
    '-d',
    vim.json.encode({
      model = requestObj.model,
      messages = requestObj.messages,
      stream = true,
      stream_options = { include_usage = true },
      tools = require('chat.tools').available_tools(),
    }),
  }

  local jobid = job.start(cmd, {
    on_stdout = requestObj.on_stdout,
    on_exit = requestObj.on_exit,
  })
  sessions.set_session_jobid(requestObj.session, jobid)
end

return M

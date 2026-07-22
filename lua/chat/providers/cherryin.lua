local M = {}

local available_models = {}

local systemObj

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  if #available_models == 0 and not systemObj then
    if config.config.api_key.cherryin then
      local cmd = curl.build_request({
        url = 'https://open.cherryin.ai/v1beta/models',
        headers = {
          'Content-Type: application/json',
          'Authorization: Bearer ' .. config.config.api_key.cherryin,
        },
      })
      systemObj = vim.system(cmd, { text = true }, function(out)
        if out.code == 0 then
          local ok, result = pcall(vim.json.decode, out.stdout)
          if ok then
            for _, model in ipairs(result.models) do
              table.insert(available_models, model.name)
            end
          end
        end
      end)
    end
  end
  return available_models
end

function M.request(opt)
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

  local cmd = curl.build_request({
    url = 'https://open.cherryin.ai/v1/chat/completions',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. config.config.api_key.cherryin,
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


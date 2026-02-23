local M = {}

local available_models = {}

local page_size = 200

local systemObj

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  if #available_models == 0 and not systemObj then
    if config.config.api_key.qwen then
      local cmd = {
        'curl',
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer ' .. config.config.api_key.qwen,
        '-s',
        'https://dashscope.aliyuncs.com/api/v1/models?page_size='
          .. page_size,
      }
      systemObj = vim.system(cmd, { text = true }, function(out)
        if out.code == 0 then
          local ok, result = pcall(vim.json.decode, out.stdout)
          if ok then
            for _, model in ipairs(result.output.models) do
              table.insert(available_models, model.model)
            end
            -- {"code":null,"message":null,"success":true,"output":{"total":417,"page_no":1,"page_size":200,"models":[]}}
            if result.output.total > page_size then
              for page = 2, math.ceil(result.output.total / page_size) do
                cmd = {
                  'curl',
                  '-H',
                  'Content-Type: application/json',
                  '-H',
                  'Authorization: Bearer ' .. config.config.api_key.qwen,
                  '-s',
                  'https://dashscope.aliyuncs.com/api/v1/models?page_no='
                    .. page
                    .. '&page_size='
                    .. page_size,
                }
                vim.system(cmd, { text = true }, function(out2)
                  if out2.code == 0 then
                    ok, result = pcall(vim.json.decode, out2.stdout)
                    if ok then
                      for _, model in ipairs(result.output.models) do
                        table.insert(available_models, model.model)
                      end
                    end
                  end
                end)
              end
            end
          end
        end
      end)
    end
  end
  return available_models
end

function M.request(opt)
  local cmd = {
    'curl',
    '-s',
    'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. config.config.api_key.qwen,
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

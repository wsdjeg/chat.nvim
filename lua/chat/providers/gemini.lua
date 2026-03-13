local M = {}

local available_models = {}

local systemObj

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

-- Use Gemini protocol
M.protocol = 'gemini'

function M.available_models()
  if #available_models == 0 and not systemObj then
    if config.config.api_key.gemini then
      local cmd = {
        'curl',
        '-s',
        string.format(
          'https://generativelanguage.googleapis.com/v1beta/models?key=%s',
          config.config.api_key.gemini
        ),
      }
      systemObj = vim.system(cmd, { text = true }, function(out)
        if out.code == 0 then
          local ok, result = pcall(vim.json.decode, out.stdout)
          if ok and result and result.models then
            available_models = {}
            for _, model in ipairs(result.models) do
              -- Only include models that support generateContent
              if model.supportedGenerationMethods then
                for _, method in ipairs(model.supportedGenerationMethods) do
                  if method == 'generateContent' then
                    local model_name = model.name:gsub('^models/', '')
                    table.insert(available_models, model_name)
                    break
                  end
                end
              end
            end
            table.sort(available_models)
          end
        end
      end)
    end
  end
  return available_models
end

function M.request(opt)
  local messages = opt.messages
  local gemini_contents = {}
  local system_instruction = nil

  -- Convert OpenAI message format to Gemini format
  for _, msg in ipairs(messages) do
    if msg.role == 'system' then
      system_instruction = {
        parts = {
          { text = msg.content },
        },
      }
    elseif msg.role == 'user' then
      table.insert(gemini_contents, {
        role = 'user',
        parts = {
          { text = msg.content },
        },
      })
    elseif msg.role == 'assistant' then
      table.insert(gemini_contents, {
        role = 'model', -- Gemini uses 'model' instead of 'assistant'
        parts = {
          { text = msg.content },
        },
      })
    elseif msg.role == 'tool' then
      -- Handle tool results
      table.insert(gemini_contents, {
        role = 'user',
        parts = {
          { text = msg.content },
        },
      })
    end
  end

  local body = {
    contents = gemini_contents,
    generationConfig = {
      temperature = 1.0,
      maxOutputTokens = 8192,
    },
  }

  if system_instruction then
    body.systemInstruction = system_instruction
  end

  -- Convert tools to Gemini format
  local tools = require('chat.tools').available_tools()
  if tools and #tools > 0 then
    body.tools = M._convert_tools(tools)
  end

  local model = sessions.get_session_model(opt.session)
  local api_key = config.config.api_key.gemini

  local cmd = {
    'curl',
    '-s',
    string.format(
      'https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?key=%s&alt=sse',
      model,
      api_key
    ),
    '-H',
    'Content-Type: application/json',
    '-X',
    'POST',
    '-d',
    '@-',
  }

  local jobid = job.start(cmd, {
    on_stdout = opt.on_stdout,
    on_stderr = opt.on_stderr,
    on_exit = opt.on_exit,
  })
  job.send(jobid, vim.json.encode(body))
  job.send(jobid, nil)
  sessions.set_session_jobid(opt.session, jobid)

  return jobid
end

-- Convert OpenAI tools format to Gemini format
function M._convert_tools(tools)
  local gemini_tools = {}
  for _, tool in ipairs(tools) do
    if tool.type == 'function' then
      table.insert(gemini_tools, {
        functionDeclarations = {
          {
            name = tool['function'].name,
            description = tool['function'].description,
            parameters = tool['function'].parameters,
          },
        },
      })
    end
  end
  return gemini_tools
end

return M

local M = {}

local job = require('job')
local sessions = require('chat.sessions')
local config = require('chat.config')

-- Use Gemini protocol
M.protocol = 'gemini'

function M.available_models()
  return {
    'gemini-1.5-pro',
    'gemini-1.5-flash',
    'gemini-1.5-flash-8b',
    'gemini-2.0-flash-exp',
  }
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
            name = tool.function.name,
            description = tool.function.description,
            parameters = tool.function.parameters,
          },
        },
      })
    end
  end
  return gemini_tools
end

return M


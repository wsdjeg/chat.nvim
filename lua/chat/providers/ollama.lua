local M = {}

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

-- Model list of the running Ollama server, filled in by the background fetch
-- below. Module level so later calls replay the cache instead of spawning a
-- second curl for the same data.
local available_models = {}

-- True while a fetch is in flight. Guards against spawning one curl per
-- caller: the /model picker and the HTTP /providers route can both ask during
-- the same tick, before the first response has arrived.
local fetching = false

-- Use OpenAI protocol (Ollama is compatible)
-- M.protocol = 'openai'  -- default, no need to specify

-- Default Ollama API endpoint
local function get_ollama_host()
  return config.config.ollama_host or 'http://localhost:11434'
end

--- Models of the Ollama server, or an empty table while loading.
---
--- The fetch is asynchronous on purpose. `available_models()` is reached from
--- the prompt window (the /model and /provider selection UIs) and from the
--- HTTP GET /providers handler, all of which run on the main loop. Calling
--- `:wait()` there froze the editor for as long as the local server took to
--- answer - and forever when it was not running at all, since curl keeps
--- retrying the connection.
---
--- So the first call only starts the background request and returns the
--- (empty) cache. Every caller already treats an empty list as "still
--- loading" (see chat.providers.available_models), and the window redraws
--- once the list arrives. A failed fetch leaves the cache empty and clears the
--- in-flight flag, so the next call retries - Ollama may simply not have been
--- started yet.
--- @return string[] Model names, empty while loading
function M.available_models()
  if #available_models == 0 and not fetching then
    fetching = true

    local cmd = curl.build_request({
      url = get_ollama_host() .. '/api/tags',
    })

    vim.system(cmd, { text = true }, function(out)
      -- Clear the flag first: a failure must not wedge the guard, otherwise a
      -- server started later would never be discovered.
      fetching = false

      if out.code ~= 0 then
        return
      end

      local ok, data = pcall(vim.json.decode, out.stdout)
      if not ok or type(data) ~= 'table' or type(data.models) ~= 'table' then
        return
      end

      for _, model in ipairs(data.models) do
        if model.name then
          table.insert(available_models, model.name)
        end
      end
    end)
  end

  return available_models
end

function M.request(opt)
  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    stream = true,
    stream_options = { include_usage = true },
    tools = require('chat.tools').request_tools(opt.session),
  })

  -- Use OpenAI-compatible endpoint: /v1/chat/completions
  local cmd = curl.build_request({
    url = get_ollama_host() .. '/v1/chat/completions',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
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


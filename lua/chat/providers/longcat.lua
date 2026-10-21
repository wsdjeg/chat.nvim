local M = {}

local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local tokens = require('chat.tokens')

function M.available_models()
  return {
    'LongCat-Flash-Chat',
    'LongCat-Flash-Thinking',
    'LongCat-Flash-Thinking-2601',
    'LongCat-Flash-Lite',
  }
end

function M.request(opt)
  local api_key, key_index = tokens.next('longcat')
  if not api_key then
    return nil
  end

  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    enable_thinking = true,
    stream = true,
    stream_options = { include_usage = true },
    tools = require('chat.tools').request_tools(opt.session),
  })

  local cmd = curl.build_request({
    url = 'https://api.longcat.chat/openai/v1/chat/completions',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. api_key,
    },
    stdin_body = true,
  })

  local jobid = job.start(cmd, {
    on_stdout = opt.on_stdout,
    on_stderr = opt.on_stderr,
    on_exit = opt.on_exit,
  })
  tokens.bind(jobid, 'longcat', key_index)
  job.send(jobid, body)
  job.send(jobid, nil)
  sessions.set_session_jobid(opt.session, jobid)

  return jobid
end

return M


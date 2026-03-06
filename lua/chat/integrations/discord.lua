local M = {}

local job = require('job')
local config = require('chat.config')

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
end

function M.send_message(content)
  if
    not config.config.integrations.discord.channel_id
    or not not config.config.integrations.discord.token
  then
    return
  end
  local cmd = {
    'curl',
    '-s',
    'https://discord.com/api/v10/channels/'
      .. config.channel_id
      .. '/messages',
    '-H',
    'Authorization: Bot ' .. config.token,
    '-H',
    'Content-Type: application/json',
    '-X',
    'POST',
    '-d',
    '@-',
  }
  local jobid = job.start(cmd, {
    on_exit = function(id, code, single) end,
  })
  job.send(
    jobid,
    vim.json.encode({
      content = content,
    })
  )
  job.send(jobid, nil)
end

function M.receive_messages(callback) end

return M

local M = {}

local job = require('job')
local config = require('chat.config')
local log = require('chat.log')

function M.send_message(content)
  if
    not config.config.integrations.discord.channel_id
    or not config.config.integrations.discord.token
  then
    log.debug('discord token or channel_id is nil')
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
    on_stdout = function(id, data)
      for _,v in ipairs(data) do log.debug(v) end
    end,
    on_stderr = function(id, data)
      for _,v in ipairs(data) do log.debug(v) end
    end,
    on_exit = function(id, code, single)
      log.debug(string.format('discord job exit code %d, single %d', code, single))
    end,
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

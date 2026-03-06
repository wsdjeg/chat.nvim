local M = {}

local job = require('job')

local config = {
  token = nil,
  channel_id = nil,
}

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
end

function M.send_message(content)
  if not config.token or not config.token then
    return
  end
  local cmd = {
    'curl',
    '-X',
    'POST',
    'https://discord.com/api/v10/channels/' .. config.channel_id .. '/messages',
    '-H',
    'Authorization: Bot ' .. config.token,
    '-H',
    'Content-Type: application/json',
    '-d',
    vim.json.encode({
      content = 'hello',
    }),
  }
end

function M.receive_messages(callback)
end

return M

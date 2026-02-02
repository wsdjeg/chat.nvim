local M = {}

function M.request(requestObj)
  local messages = {}
  if requestObj.history then
    for _, v in ipairs(requestObj.history) do
      table.insert(messages, v)
    end
  end
  table.insert(messages, { role = 'user', content = requestObj.content })
  local cmd = {
    'curl',
    '-s',
    'https://api.deepseek.com/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. requestObj.api_key,
    '-X',
    'POST',
    '-d',
    vim.json.encode({
      model = 'deepseek-chat',
      messages = messages,
      stream = false,
    }),
  }

  vim.system(cmd, { text = true }, function(obj)
    if obj.stdout then
      local result = vim.json.decode(obj.stdout)
      vim.schedule(function()
        requestObj.callback(result)
      end)
    end
  end)
end

return M


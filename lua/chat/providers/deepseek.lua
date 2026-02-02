local M = {}

function M.request(requestObj)
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
      messages = requestObj.messages,
      stream = false,
    }),
  }

  vim.system(cmd, { text = true }, function(obj)
    if obj.code ~= 0 then
      requestObj.callback(nil, 'HTTP Error:' .. obj.stderr)
    else
      if obj.stdout then
        local result = vim.json.decode(obj.stdout)
        vim.schedule(function()
          requestObj.callback(result)
        end)
      end
    end
  end)
end

return M

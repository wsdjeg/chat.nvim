local M = {}

local available_models = {}

function M.available_models()
  if #available_models == 0 then
    local config = require('chat.config')
    local cmd = {
      'curl',
      '-s',
      '-H',
      'Content-Type: application/json',
      '-H',
      'Authorization: Bearer ' .. config.config.api_key.github,
      'https://models.github.ai/catalog/models',
    }
    local systemObj = vim.system(cmd):wait()
    if systemObj.code == 0 then
      local ok, result = pcall(vim.json.decode, systemObj.stdout)
      if ok then
        for _, model in ipairs(result) do
          table.insert(available_models, model.id)
        end
      end
    end
  end
  return available_models
end

function M.request(requestObj)
  local cmd = {
    'curl',
    '-s',
    'https://models.github.ai/inference/v1/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. requestObj.api_key,
    '-X',
    'POST',
    '-d',
    vim.json.encode({
      model = requestObj.model,
      messages = requestObj.messages,
      stream = false,
    }),
  }

  vim.system(cmd, { text = true }, function(obj)
    if obj.code ~= 0 then
      requestObj.callback(nil, 'HTTP Error:' .. obj.stderr)
    else
      if obj.stdout then
        local response = vim.trim(obj.stdout)
        if response == '' then
          requestObj.callback(nil, 'empty response')
          return
        end
        local ok, result = pcall(vim.json.decode, response)
        if ok then
          if result.error then
            requestObj.callback(nil, vim.inspect(result.error))
          else
            requestObj.callback(result)
          end
        else
          requestObj.callback(nil, 'JSON parse error: ' .. result)
        end
      end
    end
  end)
end

return M

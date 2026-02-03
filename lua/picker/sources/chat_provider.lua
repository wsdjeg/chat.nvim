local M = {}

function M.get()
  return vim.tbl_map(function(t)
    t = vim.fn.fnamemodify(t, ':t:r')
    return {
      value = t,
      str = t,
    }
  end, vim.api.nvim_get_runtime_file('lua/chat/providers/*.lua', true))
end

function M.default_action(item)
  local ok, provider = pcall(require, 'chat.providers.' .. item.value)
  if ok then
    local available_models = provider.available_models()
    if #available_models > 0 then
      require('chat').setup({
        provider = item.value,
        model = available_models[1],
      })
      require('chat.windows').set_model(available_models[1])
    end
  end
end

return M

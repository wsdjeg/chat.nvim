vim.api.nvim_create_user_command('Chat', function(opt)
  require('chat').open()
end, { nargs = '*' })

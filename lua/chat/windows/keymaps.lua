local M = {}

-- Setup keymaps for result buffer
function M.setup_result_keymaps(buf, opts)
  local close_fn = opts.close_fn
  local focus_prompt_fn = opts.focus_prompt_fn

  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
    callback = close_fn,
    silent = true,
  })

  vim.api.nvim_buf_set_keymap(buf, 'n', '<C-o>', '<Nop>', {})

  vim.api.nvim_buf_set_keymap(buf, 'n', '<Tab>', '', {
    callback = focus_prompt_fn,
  })
end

-- Setup keymaps for prompt buffer
function M.setup_prompt_keymaps(buf, opts)
  local close_fn = opts.close_fn
  local focus_result_fn = opts.focus_result_fn
  local cancel_progress_fn = opts.cancel_progress_fn
  local send_message_fn = opts.send_message_fn
  local retry_message_fn = opts.retry_message_fn

  -- Disable <C-o> in prompt buffer
  vim.api.nvim_buf_set_keymap(buf, 'n', '<C-o>', '<Nop>', {})

  -- Picker keymaps (if available)
  if vim.fn.exists(':Picker') == 2 then
    vim.api.nvim_buf_set_keymap(
      buf,
      'n',
      '<leader>fr',
      '<cmd>Picker chat<Cr>',
      { noremap = true, silent = true }
    )
    vim.api.nvim_buf_set_keymap(
      buf,
      'n',
      '<leader>fp',
      '<cmd>Picker chat_provider<Cr>',
      { noremap = true, silent = true }
    )
    vim.api.nvim_buf_set_keymap(
      buf,
      'n',
      '<leader>fm',
      '<cmd>Picker chat_model<Cr>',
      { noremap = true, silent = true }
    )
  end

  -- New session
  vim.api.nvim_buf_set_keymap(
    buf,
    'n',
    '<C-n>',
    '<cmd>Chat new<Cr>',
    { silent = true }
  )

  -- Send message (Enter)
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Enter>', '', {
    callback = send_message_fn,
    silent = true,
  })

  -- Close window
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
    callback = close_fn,
    silent = true,
  })

  -- Switch focus to result window
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Tab>', '', {
    callback = focus_result_fn,
  })

  -- Cancel current request
  vim.api.nvim_buf_set_keymap(buf, 'n', '<C-c>', '', {
    callback = cancel_progress_fn,
  })

  -- Navigate sessions
  vim.api.nvim_buf_set_keymap(
    buf,
    'n',
    '<M-h>',
    '<cmd>Chat prev<Cr>',
    { silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    buf,
    'n',
    '<M-l>',
    '<cmd>Chat next<Cr>',
    { silent = true }
  )

  -- Retry last message
  vim.api.nvim_buf_set_keymap(buf, 'n', 'r', '', {
    callback = retry_message_fn,
  })
end

return M

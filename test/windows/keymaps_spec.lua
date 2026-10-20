local lu = require('luaunit')
local keymaps = require('chat.windows.keymaps')

local function keys_for(buf)
  local result = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    result[m.lhs] = m
  end
  return result
end

TestWindowsKeymaps = {}

function TestWindowsKeymaps:setUp()
  self.buf = vim.api.nvim_create_buf(false, true)
end

function TestWindowsKeymaps:tearDown()
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
end

function TestWindowsKeymaps:testSetupResultKeymaps()
  keymaps.setup_result_keymaps(self.buf, {
    close_fn = function() end,
    focus_prompt_fn = function() end,
    delete_message_fn = function() end,
  })
  local keys = keys_for(self.buf)
  lu.assertNotNil(keys['q'])
  lu.assertNotNil(keys['<Tab>'])
  lu.assertNotNil(keys['dd'])
  lu.assertNotNil(keys['<C-O>'])
end

function TestWindowsKeymaps:testSetupResultKeymapsNoDelete()
  keymaps.setup_result_keymaps(self.buf, {
    close_fn = function() end,
    focus_prompt_fn = function() end,
  })
  local keys = keys_for(self.buf)
  lu.assertNil(keys['dd'])
end

function TestWindowsKeymaps:testSetupPromptKeymaps()
  keymaps.setup_prompt_keymaps(self.buf, {
    close_fn = function() end,
    focus_result_fn = function() end,
    cancel_progress_fn = function() end,
    send_message_fn = function() end,
    retry_message_fn = function() end,
    rename_title_fn = function() end,
  })
  local keys = keys_for(self.buf)
  lu.assertNotNil(keys['<CR>'])
  lu.assertNotNil(keys['q'])
  lu.assertNotNil(keys['<Tab>'])
  lu.assertNotNil(keys['<C-C>'])
  lu.assertNotNil(keys['<C-N>'])
  lu.assertNotNil(keys['<C-D>'])
  lu.assertNotNil(keys['<M-h>'])
  lu.assertNotNil(keys['<M-l>'])
  lu.assertNotNil(keys['r'])
  lu.assertNotNil(keys['<M-t>'])
  lu.assertNotNil(keys['<C-O>'])
end

return TestWindowsKeymaps

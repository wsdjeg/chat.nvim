-- test/minimal_init.lua
-- Minimal Neovim configuration for testing

print('Initializing test environment...')

-- Set up essential settings
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = false
vim.opt.verbose = 1

-- Set up package path for:
-- 1. lua/?.lua - Main plugin source code
-- 2. test/?.lua - Mock modules (like job.lua)
-- 3. test/.deps/?.lua - Test dependencies (luaunit, luacov)
package.path = 'lua/?.lua;test/?.lua;test/.deps/?.lua;' .. package.path
vim.opt.runtimepath:prepend('.')

-- Enable luacov line coverage when COVERAGE=1 is set (see `make coverage`)
-- Must happen before any plugin source is loaded so that top-level lines count.
if vim.env.COVERAGE == '1' then
  local ok, runner = pcall(require, 'luacov.runner')
  if ok then
    runner.init({
      statsfile = vim.fn.getcwd() .. '/luacov.stats.out',
      -- luacov strips the '.lua' extension before matching include
      -- patterns, so they must not mention it
      include = { 'lua/chat/' },
    })
    _G.__luacov_runner = runner
    print('luacov enabled')
  else
    print('[WARN] luacov not available, running without coverage: ' .. tostring(runner))
  end
end

-- Create temporary test directory
local test_dir = vim.fn.tempname() .. '_chat_nvim_test'
vim.fn.mkdir(test_dir, 'p')

-- Load plugin with test configuration
local ok, err = pcall(function()
  require('chat').setup({
    provider = 'test-provider',
    model = 'test-model',
    api_key = {
      test_provider = 'test-key',
    },
    storage_dir = test_dir .. '/',
    memory = {
      enable = true,
      storage_dir = test_dir .. '/memory/',
    },
    http = {
      api_key = '', -- Disable HTTP server for tests
    },
    allowed_path = vim.fn.getcwd(),
  })
end)

if not ok then
  print('Error initializing test environment: ' .. err)
else
  print('Test environment initialized successfully')
  print('Test directory: ' .. test_dir)
end


-- test/run.lua
-- Test runner for headless Neovim

local lu = require('luaunit')

-- Add test directory to runtime path
vim.opt.runtimepath:append('.')

-- Test files to load in order
local test_files = {
  'test/util_spec.lua',
  'test/config_spec.lua',
  'test/sessions_spec.lua',
  'test/memory_spec.lua',
  'test/tools_spec.lua',
  'test/platform_spec.lua',
}

-- Run all tests
local function run_tests()
  print('=== Chat.nvim Test Suite ===')
  print('Loading test files...\n')
  
  local loaded_count = 0
  local failed_count = 0
  
  -- Load each test file
  for _, test_file in ipairs(test_files) do
    local ok, result = pcall(dofile, test_file)
    if ok then
      print(string.format('[OK] Loaded: %s', test_file))
      loaded_count = loaded_count + 1
    else
      print(string.format('[FAIL] Failed to load: %s', test_file))
      print(string.format('  Error: %s', result))
      failed_count = failed_count + 1
    end
  end
  
  print(string.format('\n=== Loaded %d/%d test files ===\n', loaded_count, #test_files))
  
  -- Run test suite
  print('Running tests...\n')
  local runner = lu.LuaUnit:new()
  runner:setOutputType('text')
  
  local success, result = pcall(function()
    return runner:runSuite()
  end)
  
  if not success then
    print(string.format('Error running test suite: %s', result))
    return 1
  end
  
  -- Return exit code based on test results
  -- LuaUnit returns: number of failures + number of errors
  if type(result) == 'number' then
    if result > 0 then
      print(string.format('\n[FAIL] %d test(s) failed', result))
      return 1
    else
      print('\n[SUCCESS] All tests passed')
      return 0
    end
  end
  
  return 0
end

-- Run tests and exit
local exit_code = run_tests()

-- Clean up temporary test files
local temp_pattern = '/tmp/chat_nvim_test_'
local temp_files = vim.fn.glob(temp_pattern .. '*', true, true)
for _, file in ipairs(temp_files) do
  vim.fn.delete(file, 'rf')
end

vim.cmd('qa!')
os.exit(exit_code)

-- lua/chat/skills/setup-nvim-plugin-test.lua
-- /setup-nvim-plugin-test - Scaffold a Neovim plugin test environment
--
-- Generates: Makefile, test/minimal_init.lua, test/run.lua, test/install_deps.lua,
--             test/example_spec.lua
--
-- Usage:
--   /setup-nvim-plugin-test              # Generate in current cwd
--   /setup-nvim-plugin-test /tmp/myplug  # Generate in specified directory

local function join(path, name)
  return path .. '/' .. name
end

local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f = io.open(path, 'w')
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

local function file_exists(path)
  return vim.fn.filereadable(path) == 1
end

-- ─── File templates ──────────────────────────────────────────

local MAKEFILE = [[
.PHONY: test test-all clean install-deps help

# Default target
help:
	@echo "Available targets:"
	@echo "  test            - Run all tests (or specific tests with PATTERN=...)"
	@echo "  clean           - Clean test cache files"
	@echo "  install-deps    - Download all test dependencies"
	@echo ""
	@echo "Examples:"
	@echo "  make test                               # Run all tests"
	@echo "  make test PATTERN=example               # Match test/**/*example*_spec.lua"

# Install all test dependencies (cross-platform, uses Lua)
install-deps:
	@nvim --headless -u test/minimal_init.lua -c "lua dofile('test/install_deps.lua')" -c "qa!"

# Run tests with nvim headless
# Supports PATTERN parameter to run specific test file(s)
test: install-deps
	@echo "Running tests with nvim --headless..."
	@nvim --headless -u test/minimal_init.lua \
		-c "lua _G.TEST_PATTERN = '$(PATTERN)'" \
		-c "lua dofile('test/run.lua')" \
		-c "qa!"

# Clean generated files
clean:
	@echo "Cleaning up..."
	@rm -rf test/*.lua~ test/*.out *.swp
	@rm -rf /tmp/*_test_* 2>/dev/null || true
]]

local MINIMAL_INIT = [[
-- test/minimal_init.lua
-- Minimal Neovim configuration for testing

print('Initializing test environment...')

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = false

-- package.path: lua/?.lua (source), test/?.lua (mocks), test/.deps/?.lua (deps)
package.path = 'lua/?.lua;test/?.lua;test/.deps/?.lua;' .. package.path
vim.opt.runtimepath:prepend('.')

-- Load your plugin here (adjust module name)
local ok, err = pcall(function()
  require('YOUR_PLUGIN').setup({})
end)

if not ok then
  print('Error initializing test environment: ' .. err)
else
  print('Test environment initialized successfully')
end
]]

local RUN_LUA = [[
-- test/run.lua
-- Test runner for headless Neovim

local lu = require('luaunit')

vim.opt.runtimepath:append('.')
package.path = 'test/?.lua;lua/?.lua;' .. package.path

-- Get test files based on PATTERN parameter
local function get_test_files()
  local pattern = _G.TEST_PATTERN
  _G.TEST_PATTERN = nil

  if not pattern or pattern == '' then
    local files = vim.split(vim.fn.globpath('test', '**/*_spec.lua'), '\n')
    if files[#files] == '' then
      table.remove(files)
    end
    return files
  end

  local files = {}
  if pattern:match('^test/') or pattern:match('^test\\') then
    if vim.fn.filereadable(pattern) == 1 then
      table.insert(files, pattern)
    else
      print(string.format('[ERROR] Test file not found: %s', pattern))
      return {}
    end
  else
    files = vim.split(vim.fn.globpath('test', string.format('**/*%s*_spec.lua', pattern)), '\n')
    local filtered = {}
    for _, f in ipairs(files) do
      if f ~= '' then
        table.insert(filtered, f)
      end
    end
    files = filtered
  end

  return files
end

local function run_tests()
  local test_files = get_test_files()

  print('=== Test Suite ===')
  print(string.format('Found %d test file(s)\n', #test_files))

  if #test_files == 0 then
    print('[ERROR] No test files found')
    return 1
  end

  local failed_count = 0
  for _, test_file in ipairs(test_files) do
    local ok, err = pcall(dofile, test_file)
    if ok then
      print(string.format('[OK] Loaded: %s', test_file))
    else
      print(string.format('[FAIL] Failed to load: %s', test_file))
      print(string.format('  Error: %s', err))
      failed_count = failed_count + 1
    end
  end

  if failed_count > 0 then
    print(string.format('[ERROR] Failed to load %d test files', failed_count))
    return 1
  end

  print('\nRunning tests...\n')
  local runner = lu.LuaUnit:new()
  runner:setOutputType('tap')
  return runner:runSuite()
end

os.exit(run_tests())
]]

local INSTALL_DEPS = [[
-- test/install_deps.lua
-- Cross-platform test dependency installer

local function mkdir(path)
  vim.fn.mkdir(path, 'p')
end

local function file_exists(path)
  return vim.fn.filereadable(path) == 1
end

local function download(url, dest)
  local has_curl = vim.fn.executable('curl') == 1
  if has_curl then
    vim.fn.system({ 'curl', '-fsSL', url, '-o', dest })
    return vim.v.shell_error == 0
  end

  if vim.fn.has('win32') == 1 then
    local ps_cmd = string.format("Invoke-WebRequest -Uri '%s' -OutFile '%s'", url, dest)
    vim.fn.system({ 'powershell', '-Command', ps_cmd })
    return vim.v.shell_error == 0
  end

  local has_wget = vim.fn.executable('wget') == 1
  if has_wget then
    vim.fn.system({ 'wget', '-q', url, '-O', dest })
    return vim.v.shell_error == 0
  end

  return false
end

local deps_dir = 'test/.deps'
mkdir(deps_dir)

-- Install luaunit
local luaunit_path = deps_dir .. '/luaunit.lua'
local luaunit_url = 'https://raw.githubusercontent.com/bluebird75/luaunit/main/luaunit.lua'

if file_exists(luaunit_path) then
  print('luaunit already installed')
else
  print('Installing luaunit...')
  if download(luaunit_url, luaunit_path) then
    print('luaunit installed to ' .. luaunit_path)
  else
    print('[ERROR] Failed to download luaunit')
    os.exit(1)
  end
end

print('All dependencies installed.')
os.exit(0)
]]

local EXAMPLE_SPEC = [[
-- test/example_spec.lua
local lu = require('luaunit')

TestExample = {}

function TestExample:setUp()
  -- Setup before each test
end

function TestExample:tearDown()
  -- Cleanup after each test
end

function TestExample:testBasic()
  lu.assertEquals(1 + 1, 2)
end

return TestExample
]]

-- ─── Skill definition ────────────────────────────────────────

return {
  name = 'setup-nvim-plugin-test',
  description = 'Scaffold a Neovim plugin test environment (Makefile + luaunit)',
  handler = function(args, ctx)
    local sessions = require('chat.sessions')

    -- Determine target directory
    local base_dir
    if args and #args > 0 then
      base_dir = vim.fs.normalize(vim.fn.fnamemodify(args, ':p'))
    else
      base_dir = sessions.get_session_cwd(ctx.session) or vim.fn.getcwd()
    end

    -- Ensure directory exists
    vim.fn.mkdir(base_dir, 'p')

    -- Detect plugin module name from lua/ directory
    local plugin_name = 'YOUR_PLUGIN'
    local lua_dirs = vim.fn.globpath(base_dir, 'lua/*', false, true)
    for _, d in ipairs(lua_dirs) do
      if vim.fn.isdirectory(d) == 1 then
        local name = vim.fn.fnamemodify(d, ':t')
        -- Check if there's an init.lua inside
        if vim.fn.filereadable(d .. '/init.lua') == 1 then
          plugin_name = name
          break
        end
      end
    end

    local files = {
      { path = 'Makefile',                  content = MAKEFILE },
      { path = 'test/minimal_init.lua',     content = MINIMAL_INIT },
      { path = 'test/run.lua',              content = RUN_LUA },
      { path = 'test/install_deps.lua',     content = INSTALL_DEPS },
      { path = 'test/example_spec.lua',     content = EXAMPLE_SPEC },
    }

    local created = {}
    local skipped = {}
    local failed = {}

    for _, f in ipairs(files) do
      local fullpath = join(base_dir, f.path)
      -- Replace placeholder in minimal_init.lua
      local content = f.content
      if f.path == 'test/minimal_init.lua' then
        content = content:gsub('YOUR_PLUGIN', plugin_name)
      end
      if file_exists(fullpath) then
        table.insert(skipped, f.path)
      else
        if write(fullpath, content) then
          table.insert(created, f.path)
        else
          table.insert(failed, f.path)
        end
      end
    end

    -- Build result message
    local lines = { '## Neovim Plugin Test Environment', '' }

    if #created > 0 then
      table.insert(lines, '**Created:**')
      for _, p in ipairs(created) do
        table.insert(lines, '  - `' .. p .. '`')
      end
      table.insert(lines, '')
    end

    if #skipped > 0 then
      table.insert(lines, '**Skipped (already exist):**')
      for _, p in ipairs(skipped) do
        table.insert(lines, '  - `' .. p .. '`')
      end
      table.insert(lines, '')
    end

    if #failed > 0 then
      table.insert(lines, '**Failed:**')
      for _, p in ipairs(failed) do
        table.insert(lines, '  - `' .. p .. '`')
      end
      table.insert(lines, '')
    end

    table.insert(lines, '### Next steps')
    table.insert(lines, '1. Edit `test/minimal_init.lua` — replace `' .. plugin_name .. '` with your plugin module')
    table.insert(lines, '2. Write tests in `test/*_spec.lua` (see `example_spec.lua`)')
    table.insert(lines, '3. Run `make test`')
    table.insert(lines, '')

    if plugin_name == 'YOUR_PLUGIN' then
      table.insert(lines, '> **Note:** Could not auto-detect plugin name. Please update `test/minimal_init.lua` manually.')
      table.insert(lines, '')
    end

    return {
      content = table.concat(lines, '\n'),
      role = 'assistant',
    }
  end,
}


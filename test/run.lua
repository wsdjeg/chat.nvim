-- test/run.lua
-- Test runner for headless Neovim

local lu = require('luaunit')

--- Per-test wall-clock profiling, enabled with `make test PROFILE=1`.
---
--- luaunit times each test with os.clock(), i.e. CPU time. The expensive parts
--- of this suite are idle waits (`vim.wait(300, function() return false end)`)
--- and subprocess round-trips, which burn almost no CPU and therefore look
--- free in luaunit's own numbers. The hooks below stamp wall time around each
--- test so the report shows what actually made the run slow.
---
--- PROFILE mode also switches luaunit to silent output: the flat TAP listing is
--- thousands of lines long and buries the report printed next to it.
local PROFILE = vim.env.PROFILE == '1'
local PROFILE_LOG = 'profile.log'

local uv = vim.uv or vim.loop

local function now_ms()
  return uv.hrtime() / 1e6
end

local run_started = now_ms()

-- Add test directory to runtime path
vim.opt.runtimepath:append('.')

-- Setup package.path to support test submodules
package.path = 'test/?.lua;lua/?.lua;' .. package.path

-- Get test files based on PATTERN parameter
local function get_test_files()
  local pattern = _G.TEST_PATTERN
  -- Clear global to avoid LuaUnit picking it up as a test name
  _G.TEST_PATTERN = nil

  if not pattern or pattern == '' then
    -- No PATTERN specified, run all tests
    local files = vim.split(vim.fn.globpath('test', '**/*_spec.lua'), '\n')
    if files[#files] == '' then
      table.remove(files)
    end
    return files
  end

  -- PATTERN parameter specified
  local files = {}

  -- Check if it's a full path
  if pattern:match('^test/') or pattern:match('^test\\') then
    -- Full path provided
    if vim.fn.filereadable(pattern) == 1 then
      table.insert(files, pattern)
    else
      print(string.format('[ERROR] Test file not found: %s', pattern))
      return {}
    end
  else
    -- Shorthand: search for matching files
    -- e.g., "write_file" -> test/**/*write_file*_spec.lua
    files = vim.split(vim.fn.globpath('test', string.format('**/*%s*_spec.lua', pattern)), '\n')

    -- Also try exact match: e.g., "tools/write_file_spec.lua"
    if #files == 0 then
      files = vim.split(vim.fn.globpath('test', string.format('%s*_spec.lua', pattern)), '\n')
    end

    -- Try with _spec.lua suffix
    if #files == 0 then
      files = vim.split(vim.fn.globpath('test', string.format('**/%s_spec.lua', pattern)), '\n')
    end

    -- Remove empty strings
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

--- Sort a list of { name = string, seconds = number } slowest first.
local function sort_slowest(entries)
  table.sort(entries, function(a, b)
    return a.seconds > b.seconds
  end)
  return entries
end

local function fmt_seconds(seconds)
  return string.format('%7.3fs', seconds)
end

--- Build the wall-clock report: slowest tests, classes and spec files to load.
local function build_profile(runner, load_times)
  local total = (now_ms() - run_started) / 1000
  local lines = {}

  local tests = {}
  local classes = {}
  for _, node in ipairs(runner.result.allTests) do
    local seconds = node.wallSeconds or 0
    -- node.testName is already "className.methodName" (luaunit builds it that
    -- way in execOneFunction), so don't prepend className again.
    tests[#tests + 1] = {
      name = node.testName,
      seconds = seconds,
    }
    local entry = classes[node.className]
    if not entry then
      entry = { name = node.className, seconds = 0, count = 0 }
      classes[node.className] = entry
    end
    entry.seconds = entry.seconds + seconds
    entry.count = entry.count + 1
  end

  local class_list = {}
  for _, entry in pairs(classes) do
    class_list[#class_list + 1] = entry
  end
  sort_slowest(class_list)
  sort_slowest(tests)

  lines[#lines + 1] = '=== Profile (wall clock) ==='
  lines[#lines + 1] = string.format('total run: %s', fmt_seconds(total))

  lines[#lines + 1] = ''
  lines[#lines + 1] = '-- slowest tests (top 25) --'
  for i = 1, math.min(25, #tests) do
    lines[#lines + 1] = string.format(
      '%s  %s',
      fmt_seconds(tests[i].seconds),
      tests[i].name
    )
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = '-- slowest classes (top 15) --'
  for i = 1, math.min(15, #class_list) do
    local entry = class_list[i]
    lines[#lines + 1] = string.format(
      '%s  %s (%d tests)',
      fmt_seconds(entry.seconds),
      entry.name,
      entry.count
    )
  end

  if load_times and #load_times > 0 then
    sort_slowest(load_times)
    lines[#lines + 1] = ''
    lines[#lines + 1] = '-- slowest spec loads (top 10) --'
    for i = 1, math.min(10, #load_times) do
      lines[#lines + 1] = string.format(
        '%s  %s',
        fmt_seconds(load_times[i].seconds / 1000),
        load_times[i].name
      )
    end
  end

  return table.concat(lines, '\n'), class_list, tests, total
end

--- Run all tests. Returns the process exit code.
local function run_tests()
  local test_files = get_test_files()

  print('=== Chat.nvim Test Suite ===')
  if _G.TEST_PATTERN and _G.TEST_PATTERN ~= '' then
    print(string.format('Filter: %s', _G.TEST_PATTERN))
  end
  print(string.format('Found %d test file(s)\n', #test_files))

  if #test_files == 0 then
    print('[ERROR] No test files found')
    return 1
  end

  local loaded_count = 0
  local failed_count = 0
  local load_times = {}

  -- Load each test file
  for _, test_file in ipairs(test_files) do
    local started = now_ms()
    local ok, err = pcall(dofile, test_file)
    if PROFILE then
      load_times[#load_times + 1] = {
        name = test_file,
        seconds = now_ms() - started,
      }
    end
    if ok then
      -- The per-file banner is noise in profile mode: the report lists loads.
      if not PROFILE then
        print(string.format('[OK] Loaded: %s', test_file))
      end
      loaded_count = loaded_count + 1
    else
      print(string.format('[FAIL] Failed to load: %s', test_file))
      print(string.format('  Error: %s', err))
      failed_count = failed_count + 1
    end
  end

  print(
    string.format(
      '\n=== Loaded %d/%d test files ===',
      loaded_count,
      #test_files
    )
  )

  if failed_count > 0 then
    print(string.format('[ERROR] Failed to load %d test files', failed_count))
    return 1
  end

  -- Run test suite (LuaUnit automatically finds all Test* classes in global namespace)
  print('\nRunning tests...\n')
  local runner = lu.LuaUnit:new()
  if PROFILE then
    -- Silent outputter: the TAP listing buries the report below it.
    runner:setOutputType('nil')
  else
    runner:setOutputType('tap')
  end

  if PROFILE then
    -- Instance-level overrides shadow the class methods, so luaunit keeps
    -- doing its own bookkeeping while we stamp wall time around each test.
    runner.startTest = function(self, testName)
      self.__wallStart = now_ms()
      return lu.LuaUnit.startTest(self, testName)
    end
    runner.endTest = function(self)
      local node = self.result.currentNode
      if node and self.__wallStart then
        node.wallSeconds = (now_ms() - self.__wallStart) / 1000
        self.__wallStart = nil
      end
      return lu.LuaUnit.endTest(self)
    end
  end

  runner:runSuite()

  -- Failures/skips come from the result tables rather than the outputter,
  -- because the silent outputter prints nothing at all.
  local failed = runner.result.failedTests
  local errored = runner.result.errorTests
  local skipped = runner.result.skippedTests

  for _, node in ipairs(failed) do
    print(string.format('[FAIL] %s.%s', node.className, node.testName))
    print('  ' .. (node.msg or ''))
  end
  for _, node in ipairs(errored) do
    print(string.format('[ERROR] %s.%s', node.className, node.testName))
    print('  ' .. (node.msg or ''))
  end
  for _, node in ipairs(skipped) do
    print(
      string.format(
        '[SKIP] %s.%s: %s',
        node.className,
        node.testName,
        node.msg or ''
      )
    )
  end

  print(
    string.format(
      '\n=== %d tests, %d passed, %d failed, %d errors, %d skipped ===',
      runner.result.runCount,
      runner.result.successCount,
      #failed,
      #errored,
      #skipped
    )
  )

  if PROFILE then
    local report, class_list, tests, total = build_profile(runner, load_times)
    local ok = pcall(vim.fn.writefile, vim.split(report, '\n'), PROFILE_LOG)
    if not ok then
      print(report)
    else
      print(string.format('Full profile written to %s', PROFILE_LOG))
    end

    -- Keep the tail readable: only the head of each table.
    print('\n=== Profile (wall clock) ===')
    print(string.format('total run: %s', fmt_seconds(total)))
    print('\n-- slowest tests --')
    for i = 1, math.min(10, #tests) do
      print(
        string.format('%s  %s', fmt_seconds(tests[i].seconds), tests[i].name)
      )
    end
    print('\n-- slowest classes --')
    for i = 1, math.min(10, #class_list) do
      local entry = class_list[i]
      print(
        string.format(
          '%s  %s (%d tests)',
          fmt_seconds(entry.seconds),
          entry.name,
          entry.count
        )
      )
    end
  end

  -- The exit code is derived from the result tables, never from runSuite()'s
  -- return value: that value comes from the outputter's endSuite(), and the
  -- silent outputter used by PROFILE mode returns nil. os.exit(nil) exits 0,
  -- which would let a failing profile run pass as green.
  if #failed + #errored > 0 or runner.result.aborted then
    return 1
  end

  return 0
end

-- Run tests and exit
local exit_code = run_tests()

-- Flush luacov stats when running with coverage (make coverage)
if _G.__luacov_runner then
  pcall(_G.__luacov_runner.shutdown)
end

-- Clean up temporary test files
local temp_pattern = '/tmp/chat_nvim_test_'
local temp_files = vim.fn.glob(temp_pattern .. '*', true, true)
for _, file in ipairs(temp_files) do
  vim.fn.delete(file, 'rf')
end

os.exit(exit_code)


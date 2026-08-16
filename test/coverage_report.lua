-- test/coverage_report.lua
-- Parse luacov.stats.out and enforce the coverage threshold for the plugin
-- sources. Report-only by default (COV_THRESHOLD=0); set COV_THRESHOLD=<n>
-- to make `make coverage` fail when overall line coverage drops below n%.
--
-- Line accounting replicates luacov's own reporter: each source line is fed
-- through luacov's LineScanner, which classifies lines as "always excluded"
-- (comments, blanks, etc.), "excluded when not hit" (structural closers like
-- `end`, `)`, `else`) or active. Only active lines count towards coverage.
--
-- Checks (when COV_THRESHOLD > 0):
--   1. line coverage: overall active-line coverage must be >= threshold
--   2. dead functions: every function definition line must appear in the
--      stats (a never-called function is never recorded by luacov, which
--      would otherwise silently inflate the percentage)
--
-- Scope: auto-discovered lua/chat/**/*.lua.
--
-- Exits with code 1 when the threshold is not met.

local THRESHOLD = tonumber(vim.env.COV_THRESHOLD or '0') or 0

package.path = 'test/.deps/?.lua;' .. package.path
local LineScanner = require('luacov.linescanner')

-- Discover scope: all plugin sources, sorted for stable output
local files = vim.split(vim.fn.globpath('lua/chat', '**/*.lua'), '\n')
table.sort(files)
for i = #files, 1, -1 do
  if files[i] == '' then
    table.remove(files, i)
  end
end

if #files == 0 then
  print('[ERROR] No source files found under lua/chat/')
  os.exit(1)
end

-- parse luacov.stats.out: chunk headers then "count count count..." lines.
-- Header formats (luacov >= 0.16 writes "<max>:<chunkname>", older wrote
-- "=<chunkname>"); both are supported here.
--
-- Unlike rooter.nvim (basename matching), chat.nvim has many files sharing
-- the same basename (init.lua, config.lua, ...), so chunk names are matched
-- against the full repo-relative path. Suffix matching also handles the
-- leading "@" of file chunk names and luacov's left-side truncation of
-- very long chunk names.
local stats = {} -- repo path -> { [line] = count }
local current
for line in io.lines('luacov.stats.out') do
  local name
  if line:sub(1, 1) == '=' then
    name = line:sub(2)
  else
    name = line:match('^%d+:(.+)$')
  end
  if name then
    current = nil
    for _, f in ipairs(files) do
      if #name >= #f and name:sub(-#f) == f then
        stats[f] = stats[f] or {}
        current = stats[f]
        break
      end
    end
  elseif current then
    local line_no = 1
    for count in line:gmatch('%d+') do
      current[line_no] = (current[line_no] or 0) + tonumber(count)
      line_no = line_no + 1
    end
  end
end

-- a function definition line (used for the dead-function check)
local function is_func_def(line)
  if line:match('^%s*%-%-') then
    return false
  end
  return line:match('^%s*local%s+function%s')
    or line:match('^%s*function%s')
    or line:match('^%s*[A-Za-z_][%w_.%[%]"\']*%s*=%s*function%s*%(')
end

local failed = false
local total_all, hit_all = 0, 0

print(string.format('=== Coverage Report (threshold: %d%%) ===', THRESHOLD))

for _, file in ipairs(files) do
  local counts = stats[file] or {}
  local total, hit = 0, 0
  local missed = {}
  local dead = {}

  local src_lines = vim.fn.readfile(file)

  -- line accounting identical to luacov's reporter
  local scanner = LineScanner:new()
  for line_no, src in ipairs(src_lines) do
    local always_excluded, excluded_when_not_hit = scanner:consume(src)
    local hits = counts[line_no] or 0
    local included = not always_excluded and (not excluded_when_not_hit or hits ~= 0)
    if included then
      total = total + 1
      if hits > 0 then
        hit = hit + 1
      else
        table.insert(missed, line_no)
      end
    end
  end

  -- dead-function check against the real source
  for line_no, src in ipairs(src_lines) do
    if is_func_def(src) and counts[line_no] == nil then
      table.insert(dead, line_no)
    end
  end

  total_all = total_all + total
  hit_all = hit_all + hit

  local pct = total > 0 and math.floor(hit / total * 100 + 0.5) or 0
  local mark = 'OK  '
  if THRESHOLD > 0 then
    if total == 0 or pct < THRESHOLD then
      mark = 'FAIL'
      failed = true
    end
  end
  print(string.format('[%s] %-44s %5d/%-5d %3d%%', mark, file, hit, total, pct))
  if THRESHOLD > 0 then
    for _, line_no in ipairs(missed) do
      print(string.format('        missed  %s:%d  %s', file, line_no, src_lines[line_no] or ''))
    end
    for _, line_no in ipairs(dead) do
      print(string.format('        function never executed  %s:%d  %s', file, line_no, src_lines[line_no] or ''))
    end
  end
end

local pct_all = total_all > 0 and math.floor(hit_all / total_all * 100 + 0.5) or 0
print(string.format('=== TOTAL  %d/%d lines  %d%% (threshold %d%%) ===', hit_all, total_all, pct_all, THRESHOLD))

if failed or pct_all < THRESHOLD then
  print('=== Coverage check FAILED ===')
  os.exit(1)
else
  print('=== Coverage check PASSED ===')
  os.exit(0)
end


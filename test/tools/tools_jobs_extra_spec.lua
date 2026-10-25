-- Coverage for the job-callback and fallback paths of move_file, ffmpeg,
-- officecli and git_config:
--   * move_file: rename failure -> copy fallback (file / directory tree /
--     unsupported type), copy failure rollback, source deletion warning,
--     overwrite removal failure
--   * ffmpeg: output extension repair, quality validation, availability
--     guard, job signal/exit branches, size ratio summaries, job start
--     failure
--   * officecli: pagination/column/json/browser flags, job callbacks
--   * git_config: validation branches and job callbacks

local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local job = require('job')

local CWD = vim.fs.normalize(vim.fn.getcwd())

local function save(module, name, holder)
  table.insert(holder, { module = module, name = name, fn = module[name] })
end

local function restore_all(holder)
  for _, entry in ipairs(holder) do
    entry.module[entry.name] = entry.fn
  end
end

-- =========================================================================
-- move_file
-- =========================================================================

TestMoveFileExtra = {}

function TestMoveFileExtra:setUp()
  self.orig = {}
  self.dir = vim.fn.tempname() .. '_move_extra/'
  vim.fn.mkdir(self.dir, 'p')
  self.allowed_path_orig = config.config.allowed_path
  config.config.allowed_path = self.dir

  self.rename_orig = vim.fn.rename
  self.delete_orig = vim.fn.delete
end

function TestMoveFileExtra:tearDown()
  vim.fn.rename = self.rename_orig
  vim.fn.delete = self.delete_orig
  config.config.allowed_path = self.allowed_path_orig
  if vim.fn.isdirectory(self.dir) == 1 then
    vim.fn.delete(self.dir, 'rf')
  end
end

--- Force the rename fast-path to fail so the copy fallback runs
local function stub_rename_fails()
  vim.fn.rename = function()
    return -1 -- rename "failed": destination never appears
  end
end

function TestMoveFileExtra:testRenameFailureFallsBackToFileCopy()
  local src = self.dir .. '/a.txt'
  vim.fn.writefile({ 'hello world' }, src)
  stub_rename_fails()

  local result = tools.call('move_file', {
    source = src,
    destination = self.dir .. '/b.txt',
  }, { cwd = self.dir })

  lu.assertStrContains(result.content, 'Successfully moved')
  lu.assertEquals(1, vim.fn.filereadable(self.dir .. '/b.txt'))
  lu.assertEquals(0, vim.fn.filereadable(src))
  lu.assertEquals(
    { 'hello world' },
    vim.fn.readfile(self.dir .. '/b.txt')
  )
end

function TestMoveFileExtra:testRenameFailureCopiesDirectoryTree()
  local src = self.dir .. '/src-dir'
  vim.fn.mkdir(src .. '/nested', 'p')
  vim.fn.writefile({ 'top' }, src .. '/top.txt')
  vim.fn.writefile({ 'deep' }, src .. '/nested/deep.txt')
  stub_rename_fails()

  local result = tools.call('move_file', {
    source = src,
    destination = self.dir .. '/dst-dir',
  }, { cwd = self.dir })

  lu.assertStrContains(result.content, 'Successfully moved')
  lu.assertEquals({ 'top' }, vim.fn.readfile(self.dir .. '/dst-dir/top.txt'))
  lu.assertEquals(
    { 'deep' },
    vim.fn.readfile(self.dir .. '/dst-dir/nested/deep.txt')
  )
  lu.assertEquals(0, vim.fn.isdirectory(src))
end

function TestMoveFileExtra:testRenameFailureUnsupportedSourceType()
  local target = self.dir .. '/target.txt'
  vim.fn.writefile({ 'x' }, target)
  local link = self.dir .. '/link-to-target'
  vim.uv.fs_symlink(target, link)
  if vim.fn.getftype(link) == '' then
    lu.fail('could not create a symlink for the test')
    return
  end
  stub_rename_fails()

  local result = tools.call('move_file', {
    source = link,
    destination = self.dir .. '/moved-link',
  }, { cwd = self.dir })

  lu.assertStrContains(result.error, 'Move failed')
  lu.assertStrContains(result.error, 'unsupported file type')
end

function TestMoveFileExtra:testCopyFailureCleansUpAndReports()
  local src = self.dir .. '/src-dir'
  vim.fn.mkdir(src, 'p')
  vim.fn.writefile({ 'data' }, src .. '/data.txt')
  -- destination path traverses through a regular file: mkdir fails
  local blocker = self.dir .. '/blocker'
  vim.fn.writefile({ 'x' }, blocker)
  stub_rename_fails()

  local result = tools.call('move_file', {
    source = src,
    destination = blocker .. '/sub',
  }, { cwd = self.dir })

  lu.assertStrContains(result.error, 'Move failed')
  lu.assertStrContains(result.error, 'Cannot create directory')
  -- cleanup did not destroy the blocking file
  lu.assertEquals(1, vim.fn.filereadable(blocker))
end

function TestMoveFileExtra:testSourceDeletionFailureWarns()
  local src = self.dir .. '/warn.txt'
  vim.fn.writefile({ 'content' }, src)
  stub_rename_fails()
  -- copy succeeds, then deleting the source fails
  vim.fn.delete = function(path, flags)
    if vim.fn.filereadable(self.dir .. '/warn-moved.txt') == 1 then
      -- copy already happened: make the source removal fail
      error('EPERM: cannot delete')
    end
    return self.delete_orig(path, flags)
  end

  local result = tools.call('move_file', {
    source = src,
    destination = self.dir .. '/warn-moved.txt',
  }, { cwd = self.dir })

  lu.assertStrContains(result.content, 'Moved (with warning)')
  lu.assertStrContains(result.content, 'failed to remove source')
  -- destination copy exists
  lu.assertEquals(1, vim.fn.filereadable(self.dir .. '/warn-moved.txt'))
  -- clean up: source still present, remove via real delete
  vim.fn.delete = self.delete_orig
  vim.fn.delete(src, 'rf')
end

function TestMoveFileExtra:testOverwriteRemovalFailure()
  local src = self.dir .. '/ow-src.txt'
  local dst = self.dir .. '/ow-dst.txt'
  vim.fn.writefile({ 'new' }, src)
  vim.fn.writefile({ 'old' }, dst)
  vim.fn.delete = function()
    error('EPERM: cannot delete destination')
  end

  local result = tools.call('move_file', {
    source = src,
    destination = dst,
    overwrite = true,
  }, { cwd = self.dir })

  lu.assertStrContains(result.error, 'Failed to remove existing destination')
end

-- =========================================================================
-- ffmpeg
-- =========================================================================

TestFfmpegExtra = {}

function TestFfmpegExtra:setUp()
  self.orig = {}
  self.dir = vim.fn.tempname() .. '_ffmpeg_extra/'
  vim.fn.mkdir(self.dir, 'p')
  self.allowed_path_orig = config.config.allowed_path
  config.config.allowed_path = self.dir
  job.intercept()

  self.input = self.dir .. '/photo.png'
  vim.fn.writefile({ '\137PNG fake image data' }, self.input)

  self.getfsize_orig = vim.fn.getfsize

  -- ffmpeg is not preinstalled on every runner (e.g. windows-latest):
  -- make the reloaded module see it as available so the job-callback
  -- branches are reachable everywhere. The job layer is intercepted, so
  -- no real ffmpeg process ever spawns.
  self.executable_orig = vim.fn.executable
  package.loaded['chat.tools.ffmpeg'] = nil
  vim.fn.executable = function(cmd)
    if cmd == 'ffmpeg' then
      return 1
    end
    return self.executable_orig(cmd)
  end
end

function TestFfmpegExtra:tearDown()
  restore_all(self.orig)
  job.reset()
  config.config.allowed_path = self.allowed_path_orig
  vim.fn.executable = self.executable_orig
  vim.fn.getfsize = self.getfsize_orig
  if vim.fn.isdirectory(self.dir) == 1 then
    vim.fn.delete(self.dir, 'rf')
  end
  package.preload['chat.tools.ffmpeg'] = nil
  package.loaded['chat.tools.ffmpeg'] = nil
end

local function ffmpeg_drive(self, action, opts)
  opts = opts or {}
  local result
  local res = tools.call('ffmpeg', vim.tbl_extend('force', {
    input = self.input,
  }, action), {
    cwd = self.dir,
    callback = function(r)
      result = r
    end,
  })
  if res.error then
    return res
  end
  local jobid = res.jobid
  if opts.stderr then
    job.emit_stderr(jobid, opts.stderr)
  end
  job.emit_exit(jobid, opts.code or 0, opts.signal or 0)
  return result
end

function TestFfmpegExtra:testOutputExtensionIsRepaired()
  local res = tools.call('ffmpeg', {
    input = self.input,
    output = self.dir .. '/out.png',
  }, { cwd = self.dir, callback = function() end })
  lu.assertNumber(res.jobid)
  local cmd = job.jobs[res.jobid].cmd
  lu.assertEquals(vim.fs.normalize(self.dir .. '/out.png.webp'), cmd[#cmd])
end

function TestFfmpegExtra:testDefaultOutputUsesWebpSibling()
  local res = tools.call('ffmpeg', {
    input = self.input,
  }, { cwd = self.dir, callback = function() end })
  local cmd = job.jobs[res.jobid].cmd
  lu.assertEquals(vim.fs.normalize(self.dir .. '/photo.webp'), cmd[#cmd])
end

function TestFfmpegExtra:testQualityNonNumberRejected()
  local result = ffmpeg_drive(self, { quality = 'high' }, {})
  lu.assertStrContains(result.error, 'quality must be a number between 0 and 100')
end

function TestFfmpegExtra:testFfmpegUnavailableGuard()
  local real_executable = vim.fn.executable
  package.loaded['chat.tools.ffmpeg'] = nil
  local restore = function()
    vim.fn.executable = real_executable
    package.loaded['chat.tools.ffmpeg'] = nil
  end
  local ok, err = pcall(function()
    vim.fn.executable = function(cmd)
      if cmd == 'ffmpeg' then
        return 0
      end
      return real_executable(cmd)
    end
    local result = tools.call('ffmpeg', { input = self.input }, { cwd = self.dir })
    lu.assertStrContains(result.error, 'ffmpeg is not installed')
  end)
  restore()
  if not ok then
    lu.fail(tostring(err))
  end
end

function TestFfmpegExtra:testJobSignalCancelled()
  local result = ffmpeg_drive(self, {}, { signal = 9 })
  lu.assertStrContains(result.error, 'ffmpeg cancelled (signal: 9)')
end

function TestFfmpegExtra:testJobExitErrorIncludesStderr()
  local result = ffmpeg_drive(self, {}, {
    stderr = { 'Invalid data found when processing input' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'ffmpeg failed (exit code: 1)')
  lu.assertStrContains(result.error, 'Invalid data found')
end

function TestFfmpegExtra:testJobExitErrorWithoutOutput()
  local result = ffmpeg_drive(self, {}, { code = 1 })
  lu.assertStrContains(result.error, 'No error output.')
end

function TestFfmpegExtra:testSuccessSummaryReportsSavedRatio()
  vim.fn.getfsize = function(path)
    if vim.endswith(path, '.webp') then
      return 500
    end
    return 1000
  end
  local result = ffmpeg_drive(self, { quality = 60 }, {})
  lu.assertStrContains(result.content, '✓ Converted to WebP')
  lu.assertStrContains(result.content, '50.0% (saved 50.0%)')
  lu.assertStrContains(result.content, 'quality: 60')
end

function TestFfmpegExtra:testSuccessSummaryReportsLargerRatio()
  vim.fn.getfsize = function(path)
    if vim.endswith(path, '.webp') then
      return 2000
    end
    return 1000
  end
  local result = ffmpeg_drive(self, {}, {})
  lu.assertStrContains(result.content, 'larger by 100.0%')
end

function TestFfmpegExtra:testSuccessSummaryHandlesMissingSizes()
  vim.fn.getfsize = function()
    return -1
  end
  local result = ffmpeg_drive(self, {}, {})
  lu.assertStrContains(result.content, 'size:   N/A')
  lu.assertStrContains(result.content, '(-)')
end

function TestFfmpegExtra:testFormatSizeUnitsAcrossScales()
  local cases = {
    { 512, '512B' },
    { 2048, '2.0KB' },
    { 3 * 1024 * 1024, '3.0MB' },
    { 2 * 1024 * 1024 * 1024, '2.0GB' },
  }
  for _, case in ipairs(cases) do
    local size, expected = case[1], case[2]
    vim.fn.getfsize = function()
      return size
    end
    local result = ffmpeg_drive(self, {}, {})
    lu.assertStrContains(result.content, expected, 'expected ' .. expected .. ' in summary')
  end
end

function TestFfmpegExtra:testJobStartFailure()
  save(job, 'start', self.orig)
  job.start = function()
    return 0
  end
  local result = tools.call('ffmpeg', { input = self.input }, { cwd = self.dir })
  lu.assertStrContains(result.error, 'Failed to start ffmpeg process.')
end

-- =========================================================================
-- officecli
-- =========================================================================

TestOfficeCliExtra = {}

function TestOfficeCliExtra:setUp()
  self.orig = {}
  self.dir = vim.fn.tempname() .. '_office_extra/'
  vim.fn.mkdir(self.dir, 'p')
  self.allowed_path_orig = config.config.allowed_path
  config.config.allowed_path = self.dir
  job.intercept()

  self.sheet = self.dir .. '/book.xlsx'
  vim.fn.writefile({ 'fake xlsx' }, self.sheet)

  -- officecli is typically not installed in CI/Termux: make the reloaded
  -- module see it as available so the job-callback branches are reachable.
  self.executable_orig = vim.fn.executable
  package.loaded['chat.tools.officecli'] = nil
  vim.fn.executable = function(cmd)
    if cmd == 'officecli' then
      return 1
    end
    return self.executable_orig(cmd)
  end
end

function TestOfficeCliExtra:tearDown()
  restore_all(self.orig)
  job.reset()
  config.config.allowed_path = self.allowed_path_orig
  vim.fn.executable = self.executable_orig
  package.loaded['chat.tools.officecli'] = nil
  if vim.fn.isdirectory(self.dir) == 1 then
    vim.fn.delete(self.dir, 'rf')
  end
end

local function officecli_drive(self, action, opts)
  opts = opts or {}
  local result
  local res = tools.call('officecli', vim.tbl_extend('force', {
    filepath = self.sheet,
  }, action), {
    cwd = self.dir,
    callback = function(r)
      result = r
    end,
  })
  if res.error then
    return res
  end
  local jobid = res.jobid
  if opts.stdout then
    job.emit_stdout(jobid, opts.stdout)
  end
  if opts.stderr then
    job.emit_stderr(jobid, opts.stderr)
  end
  job.emit_exit(jobid, opts.code or 0, opts.signal or 0)
  return result
end

function TestOfficeCliExtra:testFlagsBuildCommand()
  local res = tools.call('officecli', {
    filepath = self.sheet,
    mode = 'text',
    start = 2,
    ['end'] = 8,
    cols = 'A,B,C',
    max_lines = 40,
    json = true,
  }, { cwd = self.dir, callback = function() end })
  lu.assertNumber(res.jobid)
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, '--start 2')
  lu.assertStrContains(cmd, '--end 8')
  lu.assertStrContains(cmd, '--cols A,B,C')
  lu.assertStrContains(cmd, '--max-lines 40')
  lu.assertStrContains(cmd, '--json')
end

function TestOfficeCliExtra:testBrowserFlagOnlyForHtmlMode()
  local res = tools.call('officecli', {
    filepath = self.sheet,
    mode = 'html',
    browser = true,
  }, { cwd = self.dir, callback = function() end })
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, '--browser')
end

function TestOfficeCliExtra:testJobSignalCancelled()
  local result = officecli_drive(self, {}, { signal = 15 })
  lu.assertStrContains(result.error, 'officecli cancelled (signal: 15)')
end

function TestOfficeCliExtra:testJobSuccessIncludesOutput()
  local result = officecli_drive(self, {}, {
    stdout = { 'A1: header', 'A2: value' },
    code = 0,
  })
  lu.assertStrContains(result.content, '✓ Success')
  lu.assertStrContains(result.content, 'A1: header')
  lu.assertEquals(0, result.exit_code)
end

function TestOfficeCliExtra:testJobSuccessAppendsStderr()
  local result = officecli_drive(self, {}, {
    stderr = { 'warning: deprecated cell format' },
    code = 0,
  })
  lu.assertStrContains(result.content, 'warning: deprecated cell format')
end

function TestOfficeCliExtra:testJobFailureSummary()
  local result = officecli_drive(self, {}, { code = 1 })
  lu.assertStrContains(result.content, '✗ Failed')
  lu.assertEquals(1, result.exit_code)
end

function TestOfficeCliExtra:testJobNoOutputFallback()
  local result = officecli_drive(self, {}, { code = 0 })
  lu.assertStrContains(result.content, 'No output.')
end

function TestOfficeCliExtra:testJobStartFailure()
  save(job, 'start', self.orig)
  job.start = function()
    return 0
  end
  local result = tools.call('officecli', { filepath = self.sheet }, { cwd = self.dir })
  lu.assertStrContains(result.error, 'failed to start officecli job.')
end

function TestOfficeCliExtra:testAvailabilityCheckOnReload()
  -- override the setUp stub: make the reloaded module see officecli missing
  vim.fn.executable = function(cmd)
    if cmd == 'officecli' then
      return 0
    end
    return self.executable_orig(cmd)
  end
  package.loaded['chat.tools.officecli'] = nil
  local result = tools.call('officecli', { filepath = self.sheet }, { cwd = self.dir })
  lu.assertStrContains(result.error, 'officecli is not installed')
  -- restore the setUp-level stub for other tests
  vim.fn.executable = function(cmd)
    if cmd == 'officecli' then
      return 1
    end
    return self.executable_orig(cmd)
  end
end

-- =========================================================================
-- git_config
-- =========================================================================

TestGitConfigExtra = {}

function TestGitConfigExtra:setUp()
  self.orig = {}
  self.dir = CWD
  self.allowed_path_orig = config.config.allowed_path
  config.config.allowed_path = CWD
  job.intercept()
end

function TestGitConfigExtra:tearDown()
  job.reset()
  config.config.allowed_path = self.allowed_path_orig
end

local function git_config_drive(self, action, opts)
  opts = opts or {}
  local result
  local res = tools.call('git_config', action, {
    cwd = CWD,
    callback = function(r)
      result = r
    end,
  })
  if res.error then
    return res
  end
  local jobid = res.jobid
  if opts.stdout then
    job.emit_stdout(jobid, opts.stdout)
  end
  if opts.stderr then
    job.emit_stderr(jobid, opts.stderr)
  end
  job.emit_exit(jobid, opts.code or 0, opts.signal or 0)
  return result
end

function TestGitConfigExtra:testSetWithoutValueRejected()
  local result = git_config_drive(self, { action = 'set', key = 'user.name' }, {})
  lu.assertStrContains(result.error, 'Value is required for set action')
end

function TestGitConfigExtra:testUnsetWithoutKeyRejected()
  local result = git_config_drive(self, { action = 'unset' }, {})
  lu.assertStrContains(result.error, 'Key is required for unset action')
end

function TestGitConfigExtra:testInvalidActionRejected()
  local result = git_config_drive(self, { action = 'bogus' }, {})
  lu.assertStrContains(result.error, 'Invalid action: bogus')
end

function TestGitConfigExtra:testJobSignalCancelled()
  local result = git_config_drive(self, { action = 'list' }, { signal = 9 })
  lu.assertStrContains(result.error, 'Git config cancelled (signal: 9)')
end

function TestGitConfigExtra:testListSuccessWithOutput()
  local result = git_config_drive(self, { action = 'list' }, {
    stdout = { 'user.name=Test', 'core.editor=vim' },
    code = 0,
  })
  lu.assertStrContains(result.content, 'Git config list successful')
  lu.assertStrContains(result.content, 'user.name=Test')
end

function TestGitConfigExtra:testSetSuccessFallbackSummary()
  local result = git_config_drive(self, {
    action = 'set',
    key = 'user.email',
    value = 'a@b.c',
  }, { code = 0 })
  lu.assertStrContains(result.content, 'user.email = a@b.c')
end

function TestGitConfigExtra:testUnsetSuccessFallbackSummary()
  local result = git_config_drive(self, {
    action = 'unset',
    key = 'user.name',
  }, { code = 0 })
  lu.assertStrContains(result.content, 'user.name unset successfully.')
end

function TestGitConfigExtra:testJobExitError()
  local result = git_config_drive(self, { action = 'get', key = 'x.y' }, {
    stderr = { 'error: invalid key' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'Failed to run git config (exit 1)')
  lu.assertStrContains(result.error, 'invalid key')
end

return TestMoveFileExtra, TestFfmpegExtra, TestOfficeCliExtra, TestGitConfigExtra


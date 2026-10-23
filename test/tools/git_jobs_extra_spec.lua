-- Job-callback and info() coverage for the git_* tools.
--
-- Uses the interception mode of the test job.nvim double (job.intercept)
-- so every on_stdout/on_stderr/on_exit branch can be driven synchronously:
-- signal cancellation, success summaries, stderr concatenation, error
-- classification and the info() formatters, plus the git-unavailable
-- guard (module unload + vim.fn.executable stub).

local lu = require('luaunit')
local tools = require('chat.tools')
local job = require('job')
local config = require('chat.config')
local sessions = require('chat.sessions')

local GIT_TOOLS = {
  'git_commit',
  'git_fetch',
  'git_merge',
  'git_push',
  'git_rebase',
  'git_reset',
  'git_stash',
}

local VALID_ACTIONS = {
  git_commit = { message = 'm' },
  git_fetch = {},
  git_merge = { branch = 'main' },
  git_push = {},
  git_rebase = { branch = 'main' },
  git_reset = { mode = 'mixed' },
  git_stash = {},
}

TestGitJobsExtra = {}

function TestGitJobsExtra:setUp()
  self.allowed_path_orig = config.config.allowed_path
  config.config.allowed_path = vim.fs.normalize(vim.fn.getcwd())
  job.intercept()
  self.sessions_orig = {
    get_session_disable_force_push = sessions.get_session_disable_force_push,
  }
  sessions.get_session_disable_force_push = function()
    return false
  end
end

function TestGitJobsExtra:tearDown()
  job.reset()
  config.config.allowed_path = self.allowed_path_orig
  for k, orig in pairs(self.sessions_orig) do
    sessions[k] = orig
  end
end

--- Call a git tool with a capturing callback, optionally feed the recorded
--- job stdout/stderr lines and finish with a synthetic exit.
local function drive(tool, action, opts)
  opts = opts or {}
  local result
  local res = tools.call(tool, action, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = opts.session,
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

-- git unavailable ---------------------------------------------------------

function TestGitJobsExtra:testGitUnavailableGuardAcrossTools()
  local real_executable = vim.fn.executable
  for _, name in ipairs(GIT_TOOLS) do
    package.loaded['chat.tools.' .. name] = nil
  end
  local restore = function()
    vim.fn.executable = real_executable
    for _, name in ipairs(GIT_TOOLS) do
      package.loaded['chat.tools.' .. name] = nil
    end
  end
  local ok, err = pcall(function()
    vim.fn.executable = function(cmd)
      if cmd == 'git' then
        return 0
      end
      return real_executable(cmd)
    end
    for _, name in ipairs(GIT_TOOLS) do
      local res = tools.call(name, VALID_ACTIONS[name], {
        cwd = vim.fs.normalize(vim.fn.getcwd()),
      })
      lu.assertStrContains(res.error, 'git is not installed')
    end
  end)
  restore()
  if not ok then
    lu.fail(tostring(err))
  end
end

-- git_commit --------------------------------------------------------------

function TestGitJobsExtra:testCommitSignalCancellation()
  local result = drive('git_commit', { message = 'm' }, { signal = 9 })
  lu.assertStrContains(result.error, 'Git commit cancelled (signal: 9)')
end

function TestGitJobsExtra:testCommitSuccessSummaryWithMetadata()
  local result = drive('git_commit', { message = 'm' }, {
    stdout = {
      '[abc1234] Initial commit',
      ' 2 files changed, 3 insertions(+)',
      'branch main',
    },
    code = 0,
  })
  lu.assertStrContains(result.content, 'Git commit successful')
  lu.assertStrContains(result.content, 'Commit hash: abc1234')
  lu.assertStrContains(result.content, 'Branch: main')
  lu.assertStrContains(result.content, 'Files: 2 files')
end

function TestGitJobsExtra:testCommitSuccessAppendsStderr()
  local result = drive('git_commit', { message = 'm' }, {
    stderr = { 'warning: some hint' },
    code = 0,
  })
  lu.assertStrContains(result.content, 'warning: some hint')
end

function TestGitJobsExtra:testCommitNothingToCommitHint()
  local result = drive('git_commit', { message = 'm' }, {
    stderr = { 'nothing to commit, working tree clean' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'Nothing to commit')
end

function TestGitJobsExtra:testCommitIdentityErrorHint()
  local result = drive('git_commit', { message = 'm' }, {
    stderr = { '*** Please tell me who you are.' },
    code = 128,
  })
  lu.assertStrContains(result.error, 'Git user name and email not configured')
end

function TestGitJobsExtra:testCommitGenericExitError()
  local result = drive('git_commit', { message = 'm' }, { code = 1 })
  lu.assertStrContains(result.error, 'Failed to run git commit (exit 1)')
end

function TestGitJobsExtra:testCommitInfoFormats()
  local m = require('chat.tools.git_commit')
  lu.assertEquals(
    'git_commit message="hi" allow_empty=true amend=true',
    m.info('{"message":"hi","allow_empty":true,"amend":true}', {})
  )
  lu.assertEquals('git_commit', m.info('not-a-json', {}))
end

-- git_fetch ---------------------------------------------------------------

function TestGitJobsExtra:testFetchSignalCancellation()
  local result = drive('git_fetch', {}, { signal = 2 })
  lu.assertStrContains(result.error, 'Git fetch cancelled (signal: 2)')
end

function TestGitJobsExtra:testFetchSuccessWithOutput()
  local result = drive('git_fetch', {}, {
    stdout = { 'From origin', '   abc..def  main -> origin/main' },
    code = 0,
  })
  lu.assertStrContains(result.content, 'Git fetch successful')
  lu.assertStrContains(result.content, 'abc..def  main -> origin/main')
end

function TestGitJobsExtra:testFetchExitErrorIncludesStderr()
  local result = drive('git_fetch', {}, {
    stderr = { 'fatal: could not read from remote' },
    code = 128,
  })
  lu.assertStrContains(result.error, 'Failed to run git fetch')
  lu.assertStrContains(result.error, 'fatal: could not read from remote')
end

function TestGitJobsExtra:testFetchInfoFormats()
  local m = require('chat.tools.git_fetch')
  lu.assertEquals(
    'git_fetch remote="r" branch="b" all=true prune=true tags=true unshallow=true',
    m.info('{"remote":"r","branch":"b","all":true,"prune":true,"tags":true,"unshallow":true}', {})
  )
  lu.assertEquals('git_fetch', m.info('not-a-json', {}))
end

-- git_merge ---------------------------------------------------------------

function TestGitJobsExtra:testMergeMessageFlagInCommand()
  local res = tools.call('git_merge', {
    branch = 'feature',
    message = 'merge message',
  }, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    callback = function() end,
  })
  lu.assertNumber(res.jobid)
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, '-m merge message')
  lu.assertStrContains(cmd, 'feature')
end

function TestGitJobsExtra:testMergeSignalCancellation()
  local result = drive('git_merge', { branch = 'main' }, { signal = 15 })
  lu.assertStrContains(result.error, 'Git merge cancelled (signal: 15)')
end

function TestGitJobsExtra:testMergeContinueSummary()
  local result = drive('git_merge', { continue = true }, { code = 0 })
  lu.assertStrContains(result.content, 'Merge continued successfully.')
end

function TestGitJobsExtra:testMergeBranchSummary()
  local result = drive('git_merge', { branch = 'main' }, { code = 0 })
  lu.assertStrContains(result.content, 'Branch merged successfully.')
end

function TestGitJobsExtra:testMergeAbortSummary()
  local result = drive('git_merge', { abort = true }, { code = 0 })
  lu.assertStrContains(result.content, 'Merge aborted successfully.')
end

function TestGitJobsExtra:testMergeExitError()
  local result = drive('git_merge', { branch = 'main' }, {
    stderr = { 'CONFLICT (content): merge conflict' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'Failed to run git merge (exit 1)')
  lu.assertStrContains(result.error, 'CONFLICT (content): merge conflict')
end

function TestGitJobsExtra:testMergeInfoFormats()
  local m = require('chat.tools.git_merge')
  lu.assertEquals(
    'git_merge branch="b" message="m" no_ff=true ff_only=true abort=true continue=true',
    m.info(
      '{"branch":"b","message":"m","no_ff":true,"ff_only":true,"abort":true,"continue":true}',
      {}
    )
  )
  lu.assertEquals('git_merge', m.info('not-a-json', {}))
end

-- git_push ----------------------------------------------------------------

function TestGitJobsExtra:testPushForceDisabledForSession()
  sessions.get_session_disable_force_push = function()
    return true
  end
  local result = drive('git_push', { force = true }, { session = 's1' })
  lu.assertStrContains(result.error, 'Force push is disabled for this session')
end

function TestGitJobsExtra:testPushForceAllowedWhenNotDisabled()
  local result = drive('git_push', { force = true }, { session = 's1', code = 0 })
  lu.assertStrContains(result.content, 'Git push successful')
end

function TestGitJobsExtra:testPushFlagsBuildCommand()
  local res = tools.call('git_push', {
    force = true,
    set_upstream = true,
    tags = true,
    remote = 'upstream',
    branch = 'trunk',
  }, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    callback = function() end,
  })
  lu.assertNumber(res.jobid)
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, '--force')
  lu.assertStrContains(cmd, '-u')
  lu.assertStrContains(cmd, '--tags')
  lu.assertStrContains(cmd, 'upstream')
  lu.assertStrContains(cmd, 'trunk')
end

function TestGitJobsExtra:testPushAllFlagOmitsBranch()
  local res = tools.call('git_push', { all = true, branch = 'ignored' }, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    callback = function() end,
  })
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, '--all')
  lu.assertFalse(vim.iter(cmd:gmatch('%S+')):any(function(w)
    return w == 'ignored'
  end))
end

function TestGitJobsExtra:testPushSignalCancellation()
  local result = drive('git_push', {}, { signal = 9 })
  lu.assertStrContains(result.error, 'Git push cancelled (signal: 9)')
end

function TestGitJobsExtra:testPushSuccessSummaryEchoesCommand()
  local result = drive('git_push', {
    force = true,
    remote = 'origin',
    branch = 'main',
  }, {
    stdout = { 'To github.com:x/y.git' },
    code = 0,
  })
  lu.assertStrContains(result.content, 'Command: git push --force origin main')
  lu.assertStrContains(result.content, 'To github.com:x/y.git')
end

function TestGitJobsExtra:testPushExitError()
  local result = drive('git_push', {}, {
    stderr = { '! [rejected] main -> main (non-fast-forward)' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'Failed to run git push')
  lu.assertStrContains(result.error, 'non-fast-forward')
end

function TestGitJobsExtra:testPushInfoFormats()
  local m = require('chat.tools.git_push')
  lu.assertEquals(
    'git_push remote="r" branch="b" set_upstream=true force=true all=true tags=true',
    m.info(
      '{"remote":"r","branch":"b","set_upstream":true,"force":true,"all":true,"tags":true}',
      {}
    )
  )
  lu.assertEquals('git_push', m.info('not-a-json', {}))
end

-- git_rebase --------------------------------------------------------------

function TestGitJobsExtra:testRebaseSignalCancellation()
  local result = drive('git_rebase', { branch = 'main' }, { signal = 9 })
  lu.assertStrContains(result.error, 'Git rebase cancelled (signal: 9)')
end

function TestGitJobsExtra:testRebaseContinueSummary()
  local result = drive('git_rebase', { continue = true }, { code = 0 })
  lu.assertStrContains(result.content, 'Rebase continued successfully.')
end

function TestGitJobsExtra:testRebaseExitError()
  local result = drive('git_rebase', { branch = 'main' }, {
    stderr = { 'CONFLICT (content): rebase conflict' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'Failed to run git rebase')
  lu.assertStrContains(result.error, 'rebase conflict')
end

function TestGitJobsExtra:testRebaseInfoFormats()
  local m = require('chat.tools.git_rebase')
  lu.assertEquals(
    'git_rebase branch="b" abort=true continue=true skip=true',
    m.info('{"branch":"b","abort":true,"continue":true,"skip":true}', {})
  )
  lu.assertEquals('git_rebase', m.info('not-a-json', {}))
end

-- git_reset ---------------------------------------------------------------

function TestGitJobsExtra:testResetHardWithPathRejected()
  local result = drive('git_reset', { mode = 'hard', path = 'x.lua' }, {})
  lu.assertStrContains(result.error, 'does not support paths')
end

function TestGitJobsExtra:testResetInvalidModeRejected()
  local result = drive('git_reset', { mode = 'bogus' }, {})
  lu.assertStrContains(result.error, 'Invalid mode: bogus')
end

function TestGitJobsExtra:testResetSignalCancellation()
  local result = drive('git_reset', { mode = 'soft' }, { signal = 2 })
  lu.assertStrContains(result.error, 'Git reset cancelled (signal: 2)')
end

function TestGitJobsExtra:testResetSuccessSummaryDefaultMode()
  local result = drive('git_reset', {}, { code = 0 })
  lu.assertStrContains(result.content, 'Git reset successful')
  lu.assertStrContains(result.content, 'Reset completed in mixed mode.')
end

function TestGitJobsExtra:testResetSuccessWithOutput()
  local result = drive('git_reset', { mode = 'hard' }, {
    stdout = { 'HEAD is now at abc1234' },
    code = 0,
  })
  lu.assertStrContains(result.content, 'HEAD is now at abc1234')
  lu.assertStrContains(result.content, '--hard')
end

function TestGitJobsExtra:testResetExitError()
  local result = drive('git_reset', { mode = 'hard' }, {
    stderr = { 'fatal: ambiguous argument' },
    code = 128,
  })
  lu.assertStrContains(result.error, 'Failed to run git reset (exit 128)')
  lu.assertStrContains(result.error, 'fatal: ambiguous argument')
end

function TestGitJobsExtra:testResetInfoFormats()
  local m = require('chat.tools.git_reset')
  lu.assertEquals(
    'git_reset mode="hard" commit="abc123" path="p"',
    m.info('{"mode":"hard","commit":"abc123","path":"p"}', {})
  )
  lu.assertEquals('git_reset', m.info('not-a-json', {}))
end

-- git_stash ---------------------------------------------------------------

function TestGitJobsExtra:testStashPopWithIndexBuildsRef()
  local res = tools.call('git_stash', { action = 'pop', index = 1 }, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    callback = function() end,
  })
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, 'pop')
  lu.assertStrContains(cmd, 'stash@{1}')
end

function TestGitJobsExtra:testStashDropWithoutIndexUsesZero()
  local res = tools.call('git_stash', { action = 'drop' }, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    callback = function() end,
  })
  local cmd = table.concat(job.jobs[res.jobid].cmd, ' ')
  lu.assertStrContains(cmd, 'drop')
  lu.assertStrContains(cmd, 'stash@{0}')
end

function TestGitJobsExtra:testStashInvalidActionRejected()
  local result = drive('git_stash', { action = 'bogus' }, {})
  lu.assertStrContains(result.error, 'Invalid action: bogus')
end

function TestGitJobsExtra:testStashSignalCancellation()
  local result = drive('git_stash', {}, { signal = 9 })
  lu.assertStrContains(result.error, 'Git stash cancelled (signal: 9)')
end

function TestGitJobsExtra:testStashSaveFallbackSummary()
  local result = drive('git_stash', { action = 'save' }, { code = 0 })
  lu.assertStrContains(result.content, 'Changes saved to stash.')
end

function TestGitJobsExtra:testStashDropFallbackSummary()
  local result = drive('git_stash', { action = 'drop' }, { code = 0 })
  lu.assertStrContains(result.content, 'Stash dropped.')
end

function TestGitJobsExtra:testStashExitError()
  local result = drive('git_stash', { action = 'pop' }, {
    stderr = { 'error: Your local changes would be overwritten' },
    code = 1,
  })
  lu.assertStrContains(result.error, 'Failed to run git stash pop')
  lu.assertStrContains(result.error, 'Your local changes would be overwritten')
end

function TestGitJobsExtra:testStashInfoFormats()
  local m = require('chat.tools.git_stash')
  lu.assertEquals(
    'git_stash action="pop" message="m" index=2',
    m.info('{"action":"pop","message":"m","index":2}', {})
  )
  lu.assertEquals('git_stash', m.info('not-a-json', {}))
end

return TestGitJobsExtra


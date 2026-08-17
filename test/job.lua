--- Hybrid test double for the external `job.nvim` plugin.
--
-- Passthrough by default: commands actually run through the real job.nvim
-- module that test/install_deps.lua downloads to `test/.deps/job.lua`.
-- Tool specs (git_*, find_files, make, ...) rely on this to execute real
-- commands in temporary repos.
--
-- Specs that need deterministic streaming switch to interception mode by
-- calling `job.intercept()` in setUp. In that mode `start()` records the job
-- instead of running it, and the spec drives the callbacks via `emit_stdout`,
-- `emit_stderr` and `emit_exit`.
--
-- `job.reset()` clears recorded jobs and returns to passthrough mode, so mock
-- specs must call `job.intercept()` again after every reset.
--
-- Real callback contract (mirrored from job.nvim):
--   on_stdout(jobid, data)   data: string[] lines
--   on_stderr(jobid, data)   data: string[] lines
--   on_exit(jobid, code, signal)

-- Locate the real module next to this file (test/.deps/job.lua)
local src = debug.getinfo(1, 'S').source
if src:sub(1, 1) == '@' then
  src = src:sub(2)
end
local here = vim.fs.dirname(vim.fn.fnamemodify(src, ':p'))
local real = dofile(here .. '/.deps/job.lua')

local M = {}

local intercepted = false

--- jobid -> { cmd, opts, stdin = {}, stopped = nil|signal } (interception mode)
M.jobs = {}
local next_id = 0 -- mocked ids start at 1, matching specs that hardcode ids

--- Switch to interception mode (record jobs, do not run them).
--- `job.intercept(false)` restores passthrough.
function M.intercept(on)
  intercepted = on ~= false
end

local function is_mocked(jobid)
  return M.jobs[jobid] ~= nil
end

function M.start(cmd, opts)
  if not intercepted then
    return real.start(cmd, opts)
  end
  next_id = next_id + 1
  local jobid = next_id
  M.jobs[jobid] = {
    cmd = cmd,
    opts = opts or {},
    stdin = {},
    stopped = nil,
  }
  return jobid
end

function M.send(jobid, data)
  if is_mocked(jobid) then
    table.insert(M.jobs[jobid].stdin, data)
  else
    real.send(jobid, data)
  end
end

function M.stop(jobid, signal)
  if is_mocked(jobid) then
    M.jobs[jobid].stopped = signal or 0
  else
    real.stop(jobid, signal)
  end
end

-- Passthrough helpers for real jobs (used e.g. by mcp transports)
function M.is_running(jobid)
  return real.is_running(jobid)
end

function M.wait(jobid, timeout)
  return real.wait(jobid, timeout)
end

function M.pid(jobid)
  return real.pid(jobid)
end

function M.chanclose(jobid, t)
  return real.chanclose(jobid, t)
end

-- ---------------------------------------------------------------------------
-- Test helpers (interception mode)
-- ---------------------------------------------------------------------------

--- Simulate stdout lines for a job (calls on_stdout synchronously)
function M.emit_stdout(jobid, data)
  local j = M.jobs[jobid]
  if j and j.opts.on_stdout then
    j.opts.on_stdout(jobid, type(data) == 'table' and data or { tostring(data) })
  end
end

--- Simulate stderr lines for a job (calls on_stderr synchronously)
function M.emit_stderr(jobid, data)
  local j = M.jobs[jobid]
  if j and j.opts.on_stderr then
    j.opts.on_stderr(jobid, type(data) == 'table' and data or { tostring(data) })
  end
end

--- Simulate job exit (calls on_exit synchronously)
function M.emit_exit(jobid, code, signal)
  local j = M.jobs[jobid]
  if j and j.opts.on_exit then
    j.opts.on_exit(jobid, code or 0, signal or 0)
  end
end

--- Reset recorded jobs and return to passthrough mode.
function M.reset()
  M.jobs = {}
  next_id = 0
  intercepted = false
end

return M


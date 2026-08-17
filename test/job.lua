--- Mock of the external `job.nvim` plugin for headless tests.
-- Found via package.path (`test/?.lua`) before any system plugin.
--
-- Records started jobs instead of spawning processes. Tests can inspect
-- `M.jobs[jobid]` and simulate output/exit with M.emit_stdout/emit_stderr/emit_exit.
--
-- Real callback contract (mirrored from job.nvim):
--   on_stdout(jobid, data)   data: string[] lines
--   on_stderr(jobid, data)   data: string[] lines
--   on_exit(jobid, code, signal)
local M = {}

--- jobid -> { cmd, opts, stdin = {}, stopped = nil|signal }
M.jobs = {}
local next_id = 0

function M.start(cmd, opts)
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
  local j = M.jobs[jobid]
  if j then
    table.insert(j.stdin, data)
  end
end

function M.stop(jobid, signal)
  local j = M.jobs[jobid]
  if j then
    j.stopped = signal or 0
  end
end

-- ---------------------------------------------------------------------------
-- Test helpers
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

--- Reset recorded jobs
function M.reset()
  M.jobs = {}
  next_id = 0
end

return M


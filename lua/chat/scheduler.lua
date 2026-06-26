-- lua/chat/scheduler.lua
-- 定时任务调度模块
-- 每个任务拥有独立的 uv.timer，精确触发，无轮询
-- 支持一次性任务和周期性任务，持久化到磁盘，重启后恢复

local M = {}

local uv = vim.uv
local log = require('chat.log')

---@class ScheduledTask
---@field id string
---@field session string
---@field trigger_at? number unix timestamp for one-shot tasks
---@field interval? number seconds for periodic tasks
---@field message string
---@field created number
---@field repeat_count? number max repetitions (nil = unlimited)
---@field executed_count number
---@field timer? uv.uv_timer_t active timer handle

-- 所有任务
---@type table<string, ScheduledTask>
M.tasks = {}

-- ── 持久化 ────────────────────────────────────────────────

local function get_storage_path()
  local dir = vim.fn.stdpath('cache') .. '/chat.nvim/'
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  return dir .. 'scheduled_tasks.json'
end

local function generate_id()
  return tostring(os.time()) .. '-' .. tostring(math.random(10000, 99999))
end

--- 持久化所有任务到磁盘（不含 timer 句柄）
function M.save()
  local path = get_storage_path()
  local data = {}
  for id, task in pairs(M.tasks) do
    data[id] = {
      id = task.id,
      session = task.session,
      trigger_at = task.trigger_at,
      interval = task.interval,
      message = task.message,
      created = task.created,
      repeat_count = task.repeat_count,
      executed_count = task.executed_count,
    }
  end
  local ok, err = pcall(function()
    local f = io.open(path, 'w')
    if f then
      f:write(vim.json.encode(data))
      f:close()
    end
  end)
  if not ok then
    log.error('Failed to save scheduled tasks: ' .. tostring(err))
  end
end

-- ── 触发逻辑 ──────────────────────────────────────────────

--- 推送消息到会话队列
local function fire_task(task)
  local now = os.time()
  local msg = string.format(
    '[定时任务触发] %s\n原始任务: %s',
    os.date('%Y-%m-%d %H:%M:%S', now),
    task.message
  )
  require('chat.queue').push(task.session, msg)

  log.info(string.format(
    'Scheduled task %s fired for session %s (executed: %d/%s)',
    task.id,
    task.session,
    task.executed_count + 1,
    task.repeat_count and tostring(task.repeat_count) or '∞'
  ))
end

--- 清理任务的 timer
local function clear_timer(task)
  if task.timer then
    task.timer:stop()
    task.timer:close()
    task.timer = nil
  end
end

--- 为任务设置 timer
local function arm_task(task)
  clear_timer(task)

  local delay_ms

  if task.trigger_at then
    -- 一次性任务：计算距离触发时间的毫秒数
    local now_ms = uv.now()
    local trigger_ms = (task.trigger_at - os.time()) * 1000 + now_ms
    delay_ms = trigger_ms - now_ms
    if delay_ms < 0 then
      delay_ms = 0 -- 立即触发
    end
  elseif task.interval then
    -- 周期性任务：基于创建时间和已执行次数计算下次触发
    local now = os.time()
    local next_fire = task.created + (task.executed_count + 1) * task.interval
    delay_ms = math.max(0, (next_fire - now) * 1000)
  else
    log.error('Task ' .. task.id .. ' has no trigger_at or interval')
    return
  end

  -- uv.new_timer 超时最大值约 2^31-1 ms (~24.8 天)，超过则分片
  local max_delay = 2147483647 -- ~24.8 days in ms
  if delay_ms > max_delay then
    delay_ms = max_delay
  end

  task.timer = uv.new_timer()
  if not task.timer then
    log.error('Failed to create timer for task ' .. task.id)
    return
  end

  task.timer:start(delay_ms, 0, vim.schedule_wrap(function()
    -- 重新计算精确延迟（处理分片情况）
    local remaining_ms
    if task.trigger_at then
      remaining_ms = math.max(0, (task.trigger_at - os.time()) * 1000)
    elseif task.interval then
      local now = os.time()
      local next_fire = task.created + (task.executed_count + 1) * task.interval
      remaining_ms = math.max(0, (next_fire - now) * 1000)
    else
      remaining_ms = 0
    end

    if remaining_ms > 1000 then
      -- 还没到，重新 arm（处理 max_delay 分片）
      arm_task(task)
      return
    end

    -- 触发！
    fire_task(task)
    task.executed_count = task.executed_count + 1

    -- 判断是否需要继续
    local should_continue = false
    if task.interval then
      if not task.repeat_count or task.executed_count < task.repeat_count then
        should_continue = true
      end
    end

    if should_continue then
      -- 周期性任务：重新 arm
      arm_task(task)
      M.save()
    else
      -- 一次性任务或达到次数上限：删除
      clear_timer(task)
      M.tasks[task.id] = nil
      M.save()
      log.info('Scheduled task ' .. task.id .. ' completed and removed')
    end
  end))

  log.debug(string.format(
    'Task %s armed: delay=%dms, trigger_at=%s, interval=%s',
    task.id,
    delay_ms,
    task.trigger_at and os.date('%Y-%m-%d %H:%M:%S', task.trigger_at) or 'nil',
    task.interval and (task.interval .. 's') or 'nil'
  ))
end

-- ── 公开 API ──────────────────────────────────────────────

--- 创建定时任务
---@param opts {session: string, trigger_at?: number, interval?: number, message: string, repeat_count?: number}
---@return string task_id
function M.create(opts)
  local task = {
    id = generate_id(),
    session = opts.session,
    trigger_at = opts.trigger_at,
    interval = opts.interval,
    message = opts.message,
    created = os.time(),
    repeat_count = opts.repeat_count,
    executed_count = 0,
  }

  M.tasks[task.id] = task
  M.save()
  arm_task(task)
  return task.id
end

--- 列出所有任务
---@param session? string
---@return ScheduledTask[]
function M.list(session)
  local result = {}
  for _, task in pairs(M.tasks) do
    if not session or task.session == session then
      -- 手动浅拷贝，避免 deepcopy 遇到 userdata (timer)
      local t = {
        id = task.id,
        session = task.session,
        trigger_at = task.trigger_at,
        interval = task.interval,
        message = task.message,
        created = task.created,
        repeat_count = task.repeat_count,
        executed_count = task.executed_count,
      }
      if t.trigger_at then
        t.remaining_seconds = t.trigger_at - os.time()
      elseif t.interval then
        local next_fire = t.created + (t.executed_count + 1) * t.interval
        t.remaining_seconds = next_fire - os.time()
      end
      table.insert(result, t)
    end
  end
  table.sort(result, function(a, b)
    return a.created < b.created
  end)
  return result
end

--- 取消任务
---@param task_id string
---@return boolean
function M.cancel(task_id)
  local task = M.tasks[task_id]
  if task then
    clear_timer(task)
    M.tasks[task_id] = nil
    M.save()
    return true
  end
  return false
end

--- 获取任务详情
---@param task_id string
---@return ScheduledTask|nil
function M.get(task_id)
  return M.tasks[task_id]
end

--- 删除指定 session 的所有任务
---@param session_id string
function M.cancel_session(session_id)
  local to_cancel = {}
  for id, task in pairs(M.tasks) do
    if task.session == session_id then
      table.insert(to_cancel, id)
    end
  end
  for _, id in ipairs(to_cancel) do
    M.cancel(id)
  end
  if #to_cancel > 0 then
    log.info(string.format('Cancelled %d tasks for deleted session %s', #to_cancel, session_id))
  end
end

-- ── 生命周期 ──────────────────────────────────────────────

--- 从磁盘加载任务并 arm 所有 timer
function M.init()
  local path = get_storage_path()
  local f = io.open(path, 'r')
  if not f then
    return
  end
  local content = f:read('*a')
  f:close()
  if not content or #content == 0 then
    return
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' then
    return
  end

  local loaded = 0
  local skipped = 0
  for id, task_data in pairs(data) do
    -- 跳过已过期的一次性任务
    if task_data.interval or (task_data.trigger_at and task_data.trigger_at > os.time()) then
      local task = {
        id = task_data.id,
        session = task_data.session,
        trigger_at = task_data.trigger_at,
        interval = task_data.interval,
        message = task_data.message,
        created = task_data.created,
        repeat_count = task_data.repeat_count,
        executed_count = task_data.executed_count or 0,
      }
      M.tasks[task.id] = task
      arm_task(task)
      loaded = loaded + 1
    else
      skipped = skipped + 1
    end
  end

  if loaded > 0 or skipped > 0 then
    log.info(string.format(
      'Scheduler: loaded %d tasks, skipped %d expired',
      loaded,
      skipped
    ))
  end
end

--- 清理所有 timer
function M.shutdown()
  for _, task in pairs(M.tasks) do
    clear_timer(task)
  end
end

return M


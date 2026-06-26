-- lua/chat/tools/schedule_task.lua
-- 定时任务工具：创建、列出、取消定时任务
-- 每个任务拥有独立的 uv.timer，精确触发，无轮询

local M = {}

local scheduler = require('chat.scheduler')

---@class ChatToolsScheduleTaskAction
---@field action string "create" | "list" | "cancel"
---@field task_id? string
---@field message? string
---@field delay_seconds? number
---@field trigger_at? number
---@field interval? number
---@field repeat_count? number

-- ── 格式化辅助 ────────────────────────────────────────────

local function format_duration(seconds)
  if seconds <= 0 then
    return '即将触发'
  elseif seconds < 60 then
    return string.format('%d 秒', seconds)
  elseif seconds < 3600 then
    return string.format('%d 分 %d 秒', math.floor(seconds / 60), seconds % 60)
  elseif seconds < 86400 then
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    return string.format('%d 小时 %d 分', h, m)
  else
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    return string.format('%d 天 %d 小时', d, h)
  end
end

local function format_time(ts)
  return os.date('%Y-%m-%d %H:%M:%S', ts)
end

-- ── Scheme ─────────────────────────────────────────────────

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'schedule_task',
      description = [[Schedule a task to be executed at a future time.

This tool allows you to create, list, and cancel scheduled tasks. 
Scheduled tasks persist across Neovim restarts (stored on disk).

When a scheduled task fires, a message is injected into the target session's 
message queue, and the LLM will process it as if the user sent it.

ACTIONS:
- create: Create a new scheduled task
- list: List all scheduled tasks (optionally filtered by session)
- cancel: Cancel a scheduled task by ID

EXAMPLES:
1. One-time task with delay (check a webpage in 1 hour):
   @schedule_task action="create" message="请访问 https://example.com 并总结内容" delay_seconds=3600

2. One-time task at specific time:
   @schedule_task action="create" message="提醒我开会" trigger_at=1717200000

3. Periodic task (every 30 minutes):
   @schedule_task action="create" message="检查服务器状态" interval=1800

4. Periodic task with max repeats:
   @schedule_task action="create" message="每日总结" interval=86400 repeat_count=7

5. List all tasks:
   @schedule_task action="list"

6. Cancel a task:
   @schedule_task action="cancel" task_id="1717200000-12345"

NOTES:
- delay_seconds and trigger_at are mutually exclusive for one-time tasks
- interval creates a recurring task (use repeat_count to limit)
- Tasks survive Neovim restarts
- Maximum delay: 30 days (2592000 seconds)
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = { 'create', 'list', 'cancel' },
            description = 'Action to perform: create, list, or cancel (default: "create")',
          },
          task_id = {
            type = 'string',
            description = 'Task ID to cancel (required for cancel action)',
          },
          message = {
            type = 'string',
            description = 'Message to send when the task triggers (required for create action). Describe what the LLM should do when the task fires.',
          },
          delay_seconds = {
            type = 'number',
            description = 'Delay in seconds before the task triggers (one-time task). E.g., 3600 = 1 hour. Max 2592000 (30 days).',
            minimum = 1,
            maximum = 2592000,
          },
          trigger_at = {
            type = 'number',
            description = 'Unix timestamp when the task should trigger (one-time task). Alternative to delay_seconds.',
          },
          interval = {
            type = 'number',
            description = 'Interval in seconds for periodic tasks. E.g., 86400 = daily, 3600 = hourly.',
            minimum = 10,
            maximum = 2592000,
          },
          repeat_count = {
            type = 'number',
            description = 'Maximum number of repetitions for periodic tasks (nil = unlimited).',
            minimum = 1,
          },
        },
        required = { 'action' },
      },
    },
  }
end

-- ── Handler ────────────────────────────────────────────────

---@param action ChatToolsScheduleTaskAction
---@param ctx ChatToolContext
---@return table { content } | { error }
function M.schedule_task(action, ctx)
  action = action or {}
  local act = action.action or 'create'

  -- ─── LIST ────────────────────────────────────────────
  if act == 'list' then
    local tasks = scheduler.list(ctx.session)
    if #tasks == 0 then
      return { content = '📋 当前没有定时任务。\n\n使用 schedule_task action="create" 创建新任务。' }
    end

    local lines = { string.format('📋 共 %d 个定时任务:\n', #tasks) }
    for i, task in ipairs(tasks) do
      local icon = task.interval and '🔄' or '⏰'
      local type_str
      if task.interval then
        type_str = string.format('周期性 · 每 %s', format_duration(task.interval))
        if task.repeat_count then
          type_str = type_str .. string.format(' · %d/%d 次', task.executed_count, task.repeat_count)
        else
          type_str = type_str .. string.format(' · 已执行 %d 次', task.executed_count)
        end
      else
        type_str = '一次性'
      end

      local time_str
      if task.trigger_at then
        time_str = format_time(task.trigger_at)
        local remaining = task.remaining_seconds or (task.trigger_at - os.time())
        if remaining > 0 then
          time_str = time_str .. ' (还剩 ' .. format_duration(remaining) .. ')'
        else
          time_str = time_str .. ' (即将触发)'
        end
      elseif task.interval then
        local remaining = task.remaining_seconds or 0
        if remaining > 0 then
          time_str = '下次: ' .. format_time(os.time() + remaining)
            .. ' (还剩 ' .. format_duration(remaining) .. ')'
        else
          time_str = '即将触发'
        end
      else
        time_str = 'N/A'
      end

      table.insert(lines, string.format(
        '%s %d. `%s`\n   会话: %s | 创建: %s\n   触发: %s\n   类型: %s\n   消息: %s',
        icon, i, task.id,
        task.session,
        format_time(task.created),
        time_str,
        type_str,
        task.message
      ))
    end

    table.insert(lines, '\n取消任务: schedule_task action="cancel" task_id="<id>"')
    return { content = table.concat(lines, '\n') }
  end

  -- ─── CANCEL ──────────────────────────────────────────
  if act == 'cancel' then
    if not action.task_id then
      return { error = '取消任务需要提供 task_id。使用 action="list" 查看所有任务。' }
    end
    local ok = scheduler.cancel(action.task_id)
    if ok then
      return { content = string.format('✅ 任务 `%s` 已取消。', action.task_id) }
    else
      return { error = string.format('未找到任务 `%s`。使用 action="list" 查看所有任务。', action.task_id) }
    end
  end

  -- ─── CREATE ──────────────────────────────────────────
  if act == 'create' then
    if not action.message or #action.message == 0 then
      return { error = '创建任务需要提供 message 参数。' }
    end

    if action.delay_seconds and action.trigger_at then
      return { error = 'delay_seconds 和 trigger_at 不能同时使用。' }
    end

    if action.interval and (action.delay_seconds or action.trigger_at) then
      return { error = '周期性任务 (interval) 不能与一次性参数同时使用。' }
    end

    if not action.delay_seconds and not action.trigger_at and not action.interval then
      return { error = '请提供 delay_seconds、trigger_at 或 interval 来指定触发时间。' }
    end

    local opts = {
      session = ctx.session,
      message = action.message,
      interval = action.interval,
      repeat_count = action.repeat_count,
    }

    if action.delay_seconds then
      opts.trigger_at = os.time() + action.delay_seconds
    elseif action.trigger_at then
      opts.trigger_at = action.trigger_at
    end

    local task_id = scheduler.create(opts)

    local lines = { '✅ 定时任务已创建！\n' }
    table.insert(lines, string.format('ID: `%s`', task_id))
    table.insert(lines, string.format('会话: %s', ctx.session))

    if opts.trigger_at then
      local remaining = opts.trigger_at - os.time()
      table.insert(lines, string.format('触发时间: %s (%s后)', format_time(opts.trigger_at), format_duration(remaining)))
    end

    if action.interval then
      table.insert(lines, string.format('周期: 每 %s', format_duration(action.interval)))
      table.insert(lines, string.format('次数: %s', action.repeat_count and (action.repeat_count .. ' 次') or '无限'))
    end

    table.insert(lines, string.format('消息: %s', action.message))
    table.insert(lines, '\n💡 管理任务:')
    table.insert(lines, '  查看: schedule_task action="list"')
    table.insert(lines, string.format('  取消: schedule_task action="cancel" task_id="%s"', task_id))

    return { content = table.concat(lines, '\n') }
  end

  return { error = string.format('未知操作: %s。支持: create, list, cancel', act) }
end

-- ── Info ───────────────────────────────────────────────────

---@param action_str string|table
---@return string
function M.info(action_str, _)
  local args = action_str
  if type(action_str) == 'string' then
    local ok, decoded = pcall(vim.json.decode, action_str)
    if ok then
      args = decoded
    else
      return '📅 schedule_task'
    end
  end

  local act = args.action or 'create'
  if act == 'list' then
    return '📋 列出定时任务'
  elseif act == 'cancel' then
    return string.format('❌ 取消任务 %s', args.task_id or '?')
  else
    local parts = {}
    if args.delay_seconds then
      table.insert(parts, format_duration(args.delay_seconds) .. '后')
    elseif args.trigger_at then
      table.insert(parts, format_time(args.trigger_at))
    end
    if args.interval then
      table.insert(parts, '每' .. format_duration(args.interval))
    end
    local when = #parts > 0 and (' · ' .. table.concat(parts, ' ')) or ''
    return string.format('⏰ 创建定时任务%s', when)
  end
end

return M


-- lua/chat/plan.lua

---@alias ChatPlanStatus '"pending"'|'"in_progress"'|'"completed"'|'"paused"'|'"abandoned"'

---@alias ChatPlanStepStatus '"pending"'|'"in_progress"'|'"completed"'|'"cancelled"'

---@class ChatPlanContext
---@field working_dir string Working directory (project isolation key)
---@field session? string Session ID

---@class ChatPlanStep
---@field id integer Step ID
---@field content string Step content
---@field status '"pending"'|'"in_progress"'|'"completed"'|'"cancelled"'
---@field created_at integer Creation timestamp
---@field started_at? integer Start timestamp
---@field completed_at? integer Completion or cancellation timestamp
---@field notes? string Step notes
---@field updated_at? integer Last update timestamp

---@class ChatPlanReview
---@field completed_at? integer Completion timestamp
---@field summary? string Plan summary
---@field lessons_learned? string[] Lessons learned
---@field issues_encountered? string[] Issues encountered

---@class ChatPlan
---@field id string Plan ID (format: plan-YYYYMMDD-XXXX)
---@field title string Plan title
---@field created_at integer Creation timestamp
---@field updated_at integer Last update timestamp
---@field status '"pending"'|'"in_progress"'|'"completed"'|'"paused"'|'"abandoned"'
---@field steps ChatPlanStep[] Plan steps
---@field context ChatPlanContext Plan context
---@field review ChatPlanReview Plan review
---@field next_step_id integer Next step ID counter (stable IDs)
---@field paused_at? integer Pause timestamp
---@field pause_reason? string Pause or cancel reason
---@field resumed_at? integer Resume timestamp

local M = {}
local config = require('chat.config')
local working_memory = require('chat.memory.working')

---@type ChatPlan[]
local plans = {}

local loaded = false

---Ensure plans are loaded from storage (lazy loading)
local function ensure_loaded()
  if not loaded then
    M.load()
  end
end

---Generate plan ID with collision detection
---@return string Plan ID in format plan-YYYYMMDD-XXXX
local function generate_plan_id()
  local id
  repeat
    id = string.format(
      'plan-%s-%s',
      os.date('%Y%m%d'),
      math.random(1000, 9999)
    )
  until not M.get(id)
  return id
end

---Check if all steps are done (completed or cancelled)
---@param steps ChatPlanStep[] Steps to check
---@return boolean True if all steps are completed or cancelled
local function is_all_done(steps)
  for _, step in ipairs(steps) do
    if step.status ~= 'completed' and step.status ~= 'cancelled' then
      return false
    end
  end
  return true
end

---Create new plan
---@param title string Plan title
---@param steps? string[] Initial steps
---@param context? ChatPlanContext Plan context
---@return ChatPlan Created plan
function M.create(title, steps, context)
  ensure_loaded()
  local plan = {
    id = generate_plan_id(),
    title = title,
    created_at = os.time(),
    updated_at = os.time(),
    status = 'pending',
    steps = {},
    next_step_id = 1,
    context = context or {
      working_dir = vim.fn.getcwd(),
      session = nil,
    },
    review = {
      completed_at = nil,
      summary = '',
      lessons_learned = {},
      issues_encountered = {},
    },
  }

  -- Add initial steps
  for _, step_content in ipairs(steps or {}) do
    table.insert(plan.steps, {
      id = plan.next_step_id,
      content = step_content,
      status = 'pending',
      created_at = os.time(),
      started_at = nil,
      completed_at = nil,
      notes = '',
    })
    plan.next_step_id = plan.next_step_id + 1
  end

  table.insert(plans, plan)
  M.save()

  -- Auto store to working memory
  working_memory.store(
    context and context.session,
    'system',
    string.format('[plan] Created: %s', title)
  )

  return plan
end

---Get plan by ID
---@param plan_id string Plan ID
---@return ChatPlan|nil Plan if found, nil otherwise
function M.get(plan_id)
  ensure_loaded()
  for _, plan in ipairs(plans) do
    if plan.id == plan_id then
      return plan
    end
  end
  return nil
end

---List plans, optionally filtered by status, session, and/or working_dir
---@param status? string Filter by status (optional)
---@param working_dir? string Filter by working directory (project isolation)
---@param session? string Filter by session (session isolation, default when provided)
---@param include_project? boolean When true, also include plans from same working_dir
---@return ChatPlan[] List of plans sorted by created_at descending
function M.list(status, working_dir, session, include_project)
  ensure_loaded()

  -- Work on a copy to avoid mutating the original plans table
  local filtered = vim.list_extend({}, plans)

  if status then
    filtered = vim.tbl_filter(function(p)
      return p.status == status
    end, filtered)
  end

  if session then
    -- Session isolation (default): only show plans from current session
    -- When include_project is true, also include plans from same working_dir
    filtered = vim.tbl_filter(function(p)
      -- Same session: always include
      if p.context and p.context.session == session then
        return true
      end
      -- Different session but same project: include only if requested
      if
        include_project
        and working_dir
        and p.context
        and p.context.working_dir == working_dir
      then
        return true
      end
      return false
    end, filtered)
  elseif working_dir then
    -- Backward compat: if no session, filter by working_dir only
    filtered = vim.tbl_filter(function(p)
      return p.context and p.context.working_dir == working_dir
    end, filtered)
  end

  -- Sort by created_at descending (newest first)
  table.sort(filtered, function(a, b)
    return a.created_at > b.created_at
  end)

  return filtered
end

---Add step to plan
---@param plan_id string Plan ID
---@param step_content string Step content
---@return ChatPlanStep|nil step Added step if success
---@return string|nil error Error message if failed
function M.add_step(plan_id, step_content)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Cannot add steps to a ' .. plan.status .. ' plan. Use reopen first.'
  end

  -- Ensure next_step_id exists (backward compat for old plans without it)
  plan.next_step_id = plan.next_step_id or (#plan.steps + 1)

  local step = {
    id = plan.next_step_id,
    content = step_content,
    status = 'pending',
    created_at = os.time(),
    started_at = nil,
    completed_at = nil,
    notes = '',
  }

  table.insert(plan.steps, step)
  plan.next_step_id = plan.next_step_id + 1
  plan.updated_at = os.time()

  M.save()
  return step
end

---Start next pending step
---@param plan_id string Plan ID
---@return ChatPlanStep|nil step Started step if success
---@return string|nil error Error message if failed
function M.start_next(plan_id)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'paused' then
    return nil, 'Plan is paused. Use resume action first.'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Plan is ' .. plan.status .. '. Use reopen action first.'
  end

  -- Find first pending step
  for _, step in ipairs(plan.steps) do
    if step.status == 'pending' then
      step.status = 'in_progress'
      step.started_at = os.time()
      step.updated_at = os.time()
      plan.status = 'in_progress'
      plan.updated_at = os.time()
      M.save()

      -- Update working memory
      working_memory.store(
        plan.context and plan.context.session,
        'system',
        string.format('[plan] Started step %d: %s', step.id, step.content)
      )

      return step
    end
  end

  return nil, 'No pending steps'
end

---Complete step
---@param plan_id string Plan ID
---@param step_id integer Step ID
---@param notes? string Completion notes
---@return ChatPlanStep|nil step Completed step if success
---@return string|nil error Error message if failed
function M.complete_step(plan_id, step_id, notes)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Plan is ' .. plan.status .. '. Use reopen first.'
  end

  for _, step in ipairs(plan.steps) do
    if step.id == step_id then
      if step.status == 'completed' then
        return nil, 'Step is already completed'
      end
      if step.status == 'cancelled' then
        return nil, 'Cannot complete a cancelled step'
      end

      step.status = 'completed'
      step.completed_at = os.time()
      step.updated_at = os.time()
      step.notes = notes or step.notes
      plan.updated_at = os.time()

      -- Check if all steps completed or cancelled
      if is_all_done(plan.steps) then
        plan.status = 'completed'
        plan.review.completed_at = os.time()
      end

      M.save()
      return step
    end
  end

  return nil, 'Step not found'
end

---Cancel step (mark as cancelled)
---@param plan_id string Plan ID
---@param step_id integer Step ID
---@param reason? string Cancellation reason
---@return ChatPlanStep|nil step Cancelled step if success
---@return string|nil error Error message if failed
function M.cancel_step(plan_id, step_id, reason)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Plan is ' .. plan.status .. '. Use reopen first.'
  end

  for _, step in ipairs(plan.steps) do
    if step.id == step_id then
      if step.status == 'completed' then
        return nil, 'Cannot cancel a completed step'
      end
      if step.status == 'cancelled' then
        return nil, 'Step is already cancelled'
      end

      step.status = 'cancelled'
      step.completed_at = os.time()
      step.updated_at = os.time()
      step.notes = reason or step.notes
      plan.updated_at = os.time()

      -- Check if all steps completed or cancelled
      if is_all_done(plan.steps) then
        plan.status = 'completed'
        plan.review.completed_at = os.time()
      end

      M.save()
      return step
    end
  end

  return nil, 'Step not found'
end

---Delete step from plan
---@param plan_id string Plan ID
---@param step_id integer Step ID
---@return ChatPlan|nil plan Updated plan if success
---@return string|nil error Error message if failed
function M.delete_step(plan_id, step_id)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Plan is ' .. plan.status .. '. Use reopen first.'
  end

  local found = false
  for i, step in ipairs(plan.steps) do
    if step.id == step_id then
      table.remove(plan.steps, i)
      found = true
      break
    end
  end

  if not found then
    return nil, 'Step not found'
  end

  plan.updated_at = os.time()
  M.save()
  return plan
end

---Update step content
---@param plan_id string Plan ID
---@param step_id integer Step ID
---@param content string New step content
---@return ChatPlanStep|nil step Updated step if success
---@return string|nil error Error message if failed
function M.update_step(plan_id, step_id, content)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Plan is ' .. plan.status .. '. Use reopen first.'
  end

  for _, step in ipairs(plan.steps) do
    if step.id == step_id then
      step.content = content or step.content
      step.updated_at = os.time()
      plan.updated_at = os.time()
      M.save()
      return step
    end
  end

  return nil, 'Step not found'
end

---Reorder steps in plan
---@param plan_id string Plan ID
---@param step_ids integer[] Ordered list of step IDs
---@return ChatPlan|nil plan Updated plan if success
---@return string|nil error Error message if failed
function M.reorder_steps(plan_id, step_ids)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' or plan.status == 'abandoned' then
    return nil, 'Plan is ' .. plan.status .. '. Use reopen first.'
  end

  if #step_ids ~= #plan.steps then
    return nil, 'Step count mismatch'
  end

  local step_map = {}
  for _, step in ipairs(plan.steps) do
    step_map[step.id] = step
  end

  local new_steps = {}
  for _, id in ipairs(step_ids) do
    if not step_map[id] then
      return nil, 'Step not found: ' .. tostring(id)
    end
    table.insert(new_steps, step_map[id])
  end

  plan.steps = new_steps
  plan.updated_at = os.time()
  M.save()
  return plan
end

---Pause an in_progress plan
---@param plan_id string Plan ID
---@param reason? string Pause reason
---@return ChatPlan|nil plan Paused plan if success
---@return string|nil error Error message if failed
function M.pause(plan_id, reason)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status ~= 'in_progress' then
    return nil, 'Only in_progress plans can be paused (current: ' .. plan.status .. ')'
  end

  plan.status = 'paused'
  plan.paused_at = os.time()
  plan.pause_reason = reason
  plan.updated_at = os.time()
  M.save()

  return plan
end

---Resume a paused plan
---@param plan_id string Plan ID
---@return ChatPlan|nil plan Resumed plan if success
---@return string|nil error Error message if failed
function M.resume(plan_id)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status ~= 'paused' then
    return nil, 'Only paused plans can be resumed (current: ' .. plan.status .. ')'
  end

  plan.status = 'in_progress'
  plan.resumed_at = os.time()
  plan.updated_at = os.time()
  M.save()

  return plan
end

---Update plan title
---@param plan_id string Plan ID
---@param title string New title
---@return ChatPlan|nil plan Updated plan if success
---@return string|nil error Error message if failed
function M.update_title(plan_id, title)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if not title or title == '' then
    return nil, 'Title is required'
  end

  plan.title = title
  plan.updated_at = os.time()
  M.save()
  return plan
end

---Cancel (abandon) a plan
---@param plan_id string Plan ID
---@param reason? string Cancellation reason
---@return ChatPlan|nil plan Cancelled plan if success
---@return string|nil error Error message if failed
function M.cancel(plan_id, reason)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status == 'completed' then
    return nil, 'Cannot cancel a completed plan'
  end

  if plan.status == 'abandoned' then
    return nil, 'Plan is already abandoned'
  end

  plan.status = 'abandoned'
  plan.paused_at = os.time()
  plan.pause_reason = reason
  plan.updated_at = os.time()
  M.save()
  return plan
end

---Reopen a completed or abandoned plan
---@param plan_id string Plan ID
---@return ChatPlan|nil plan Reopened plan if success
---@return string|nil error Error message if failed
function M.reopen(plan_id)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status ~= 'completed' and plan.status ~= 'abandoned' then
    return nil, 'Only completed or abandoned plans can be reopened (current: ' .. plan.status .. ')'
  end

  -- Check if there are any non-completed, non-cancelled steps
  local has_pending = false
  for _, step in ipairs(plan.steps) do
    if step.status ~= 'completed' and step.status ~= 'cancelled' then
      has_pending = true
      break
    end
  end

  plan.status = has_pending and 'in_progress' or 'pending'
  plan.review.completed_at = nil
  plan.updated_at = os.time()
  M.save()
  return plan
end

---Add review to a completed or abandoned plan
---@param plan_id string Plan ID
---@param summary? string Plan summary
---@param lessons? string[] Lessons learned
---@param issues? string[] Issues encountered
---@return ChatPlan|nil plan Reviewed plan if success
---@return string|nil error Error message if failed
function M.review_plan(plan_id, summary, lessons, issues)
  ensure_loaded()
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  if plan.status ~= 'completed' and plan.status ~= 'abandoned' then
    return nil, 'Only completed or abandoned plans can be reviewed (current: ' .. plan.status .. ')'
  end

  plan.review.summary = summary or ''
  plan.review.lessons_learned = lessons or {}
  plan.review.issues_encountered = issues or {}
  plan.review.completed_at = plan.review.completed_at or os.time()

  M.save()

  -- Extract key lessons to long-term memory (with project session context)
  if lessons and #lessons > 0 then
    local content = string.format(
      '[plan_review] %s: %s',
      plan.title,
      table.concat(lessons, '; ')
    )
    pcall(function()
      require('chat.memory').store_memory(
        plan.context and plan.context.session,
        'system',
        content,
        'long_term'
      )
    end)
  end

  return plan
end

---Delete plan
---@param plan_id string Plan ID
function M.delete(plan_id)
  ensure_loaded()
  plans = vim.tbl_filter(function(p)
    return p.id ~= plan_id
  end, plans)
  M.save()
end

---Load plans from storage with validation and migration
function M.load()
  local path = config.config.memory.storage_dir .. 'plans.json'
  local file = io.open(path, 'r')
  if file then
    local ok, data = pcall(vim.json.decode, file:read('*a'))
    file:close()
    if ok and type(data) == 'table' then
      -- Validate and migrate each plan
      for _, plan in ipairs(data) do
        plan.steps = plan.steps or {}
        plan.context = plan.context
          or { working_dir = vim.fn.getcwd(), session = nil }
        plan.context.working_dir = plan.context.working_dir
          or vim.fn.getcwd()
        plan.review = plan.review or {}
        plan.review.summary = plan.review.summary or ''
        plan.review.lessons_learned = plan.review.lessons_learned or {}
        plan.review.issues_encountered = plan.review.issues_encountered or {}
        plan.next_step_id = plan.next_step_id or (#plan.steps + 1)
        -- Ensure steps have required fields
        for _, step in ipairs(plan.steps) do
          step.notes = step.notes or ''
          step.status = step.status or 'pending'
        end
      end
      plans = data
    elseif ok then
      vim.notify('[chat.nvim] plans.json is not a valid table', vim.log.levels.WARN)
    else
      vim.notify('[chat.nvim] Failed to parse plans.json', vim.log.levels.WARN)
    end
  end
  loaded = true
end

---Save plans to storage
function M.save()
  local path = config.config.memory.storage_dir .. 'plans.json'
  local file = io.open(path, 'w')
  if file then
    file:write(vim.json.encode(plans))
    file:close()
  else
    vim.notify('[chat.nvim] Failed to save plans to ' .. path, vim.log.levels.WARN)
  end
end

return M


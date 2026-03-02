-- lua/chat/plan.lua
local M = {}
local config = require('chat.config')
local working_memory = require('chat.memory.working')

local plans = {}

-- Generate plan ID
local function generate_plan_id()
  return string.format(
    'plan-%s-%s',
    os.date('%Y%m%d'),
    math.random(1000, 9999)
  )
end

-- Create new plan
function M.create(title, steps, context)
  local plan = {
    id = generate_plan_id(),
    title = title,
    created_at = os.time(),
    updated_at = os.time(),
    status = 'pending',
    steps = {},
    context = context or {
      working_dir = vim.fn.getcwd(),
      session = nil,
      related_files = {},
    },
    review = {
      completed_at = nil,
      summary = '',
      lessons_learned = {},
      issues_encountered = {},
    },
  }

  -- Add initial steps
  for i, step_content in ipairs(steps or {}) do
    table.insert(plan.steps, {
      id = i,
      content = step_content,
      status = 'pending',
      created_at = os.time(),
      started_at = nil,
      completed_at = nil,
      notes = '',
    })
  end

  table.insert(plans, plan)
  M.save()

  -- Auto store to working memory
  working_memory.store(
    nil,
    'system',
    string.format('[plan] Created: %s', title)
  )

  return plan
end

-- Get plan by ID
function M.get(plan_id)
  for _, plan in ipairs(plans) do
    if plan.id == plan_id then
      return plan
    end
  end
  return nil
end

-- List all plans
function M.list(status)
  if not status then
    return plans
  end

  return vim.tbl_filter(function(p)
    return p.status == status
  end, plans)
end

-- Add step to plan
function M.add_step(plan_id, step_content)
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  local step = {
    id = #plan.steps + 1,
    content = step_content,
    status = 'pending',
    created_at = os.time(),
    started_at = nil,
    completed_at = nil,
    notes = '',
  }

  table.insert(plan.steps, step)
  plan.updated_at = os.time()

  if plan.status == 'pending' then
    plan.status = 'in_progress'
  end

  M.save()
  return step
end

-- Start next step
function M.start_next(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  -- Find first pending step
  for _, step in ipairs(plan.steps) do
    if step.status == 'pending' then
      step.status = 'in_progress'
      step.started_at = os.time()
      plan.status = 'in_progress'
      plan.updated_at = os.time()
      M.save()

      -- Update working memory
      working_memory.store(
        nil,
        'system',
        string.format('[plan] Started step %d: %s', step.id, step.content)
      )

      return step
    end
  end

  return nil, 'No pending steps'
end

local function tbl_every(check, items)
  for _, item in ipairs(items) do
    if not check(item) then
      return false
    end
  end
  return true
end

-- Complete step
function M.complete_step(plan_id, step_id, notes)
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  for _, step in ipairs(plan.steps) do
    if step.id == step_id then
      step.status = 'completed'
      step.completed_at = os.time()
      step.notes = notes or step.notes
      plan.updated_at = os.time()

      -- Check if all steps completed
      local all_done = tbl_every(function(s)
        return s.status == 'completed'
      end, plan.steps)

      if all_done then
        plan.status = 'completed'
        plan.review.completed_at = os.time()
      end

      M.save()
      return step
    end
  end

  return nil, 'Step not found'
end

-- Complete plan and review
function M.review_plan(plan_id, summary, lessons, issues)
  local plan = M.get(plan_id)
  if not plan then
    return nil, 'Plan not found'
  end

  plan.review.summary = summary or ''
  plan.review.lessons_learned = lessons or {}
  plan.review.issues_encountered = issues or {}
  plan.status = 'completed'

  M.save()

  -- Extract key lessons to long-term memory
  if #lessons > 0 then
    local content = string.format(
      '[plan_review] %s: %s',
      plan.title,
      table.concat(lessons, '; ')
    )
    require('chat.memory').store_memory(nil, 'system', content, 'long_term')
  end

  return plan
end

-- Delete plan
function M.delete(plan_id)
  plans = vim.tbl_filter(function(p)
    return p.id ~= plan_id
  end, plans)
  M.save()
end

-- Load/Save
function M.load()
  local path = config.config.memory.storage_dir .. 'plans.json'
  local file = io.open(path, 'r')
  if file then
    local ok, data = pcall(vim.json.decode, file:read('*a'))
    file:close()
    if ok then
      plans = data
    end
  end
end

function M.save()
  local path = config.config.memory.storage_dir .. 'plans.json'
  local file = io.open(path, 'w')
  if file then
    file:write(vim.json.encode(plans))
    file:close()
  end
end

M.load()

return M

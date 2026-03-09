local M = {}
local plan_module = require('chat.plan')
local config = require('chat.config')

function M.plan(arguments, ctx)
  local action = arguments.action
  local title = arguments.title
  local steps = arguments.steps
  local plan_id = arguments.plan_id
  local step_content = arguments.step_content
  local notes = arguments.notes

  if not config.config.memory or not config.config.memory.enable then
    return { error = 'Memory system is not enabled.' }
  end

  -- Create new plan
  if action == 'create' then
    if not title then
      return { error = 'Plan title is required for create action.' }
    end

    local plan = plan_module.create(title, steps, {
      working_dir = vim.fn.getcwd(),
      session = ctx.session,
    })

    return {
      content = string.format(
        '✅ Plan created: **%s**\n'
          .. 'ID: `%s`\n'
          .. 'Steps: %d\n\n'
          .. 'Use `@plan action="next" plan_id="%s"` to start first step.',
        plan.title,
        plan.id,
        #plan.steps,
        plan.id
      ),
    }
  end

  -- Show plan details
  if action == 'show' then
    local plan = plan_module.get(plan_id)
    if not plan then
      return { error = 'Plan not found: ' .. plan_id }
    end

    local output = {
      string.format('# 📋 Plan: %s', plan.title),
      string.format('**ID:** %s', plan.id),
      string.format('**Status:** %s', plan.status),
      string.format(
        '**Created:** %s',
        os.date('%Y-%m-%d %H:%M', plan.created_at)
      ),
      '',
      '## Steps:',
    }

    for _, step in ipairs(plan.steps) do
      local status_icon = step.status == 'completed' and '✅'
        or step.status == 'in_progress' and '⏳'
        or '⬜'
      local step_line =
        string.format('%s **%d.** %s', status_icon, step.id, step.content)
      if step.notes and #step.notes > 0 then
        step_line = step_line .. string.format('\n   📝 %s', step.notes)
      end
      table.insert(output, step_line)
    end

    if plan.status == 'completed' and plan.review.summary then
      table.insert(output, '')
      table.insert(output, '## Review:')
      table.insert(output, plan.review.summary)
    end

    return { content = table.concat(output, '\n') }
  end

  -- List all plans
  if action == 'list' then
    local status = arguments.status
    local plans = plan_module.list(status)

    if #plans == 0 then
      return { content = 'No plans found.' }
    end

    local output = { '# 📚 All Plans\n' }
    for _, plan in ipairs(plans) do
      local completed = #vim.tbl_filter(function(s)
        return s.status == 'completed'
      end, plan.steps)
      local progress = string.format('%d/%d', completed, #plan.steps)

      table.insert(
        output,
        string.format(
          '- **%s** (`%s`) - %s [%s]',
          plan.title,
          plan.id,
          plan.status,
          progress
        )
      )
    end

    return { content = table.concat(output, '\n') }
  end

  -- Add step to plan
  if action == 'add' then
    if not plan_id or not step_content then
      return { error = 'plan_id and step_content are required.' }
    end

    local step, err = plan_module.add_step(plan_id, step_content)
    if not step then
      return { error = err }
    end

    return {
      content = string.format(
        '✅ Step added to plan: **%d.** %s',
        step.id,
        step.content
      ),
    }
  end

  -- Start next step
  if action == 'next' then
    local step, err = plan_module.start_next(plan_id)
    if not step then
      return { error = err or 'No pending steps.' }
    end

    return {
      content = string.format(
        '⏳ **Started Step %d:** %s\n\n'
          .. 'Use `@plan action="done" plan_id="%s" step_id=%d` to mark as completed.',
        step.id,
        step.content,
        plan_id,
        step.id
      ),
    }
  end

  -- Complete step
  if action == 'done' then
    local step_id = arguments.step_id
    if not step_id then
      -- Find current in_progress step
      local plan = plan_module.get(plan_id)
      if not plan then
        return { error = 'Plan not found.' }
      end

      for _, s in ipairs(plan.steps) do
        if s.status == 'in_progress' then
          step_id = s.id
          break
        end
      end

      if not step_id then
        return { error = 'No step in progress. Use step_id parameter.' }
      end
    end

    local step, err = plan_module.complete_step(plan_id, step_id, notes)
    if not step then
      return { error = err }
    end

    local plan = plan_module.get(plan_id)
    local is_plan_done = plan.status == 'completed'

    local content =
      string.format('✅ **Completed Step %d:** %s', step.id, step.content)

    if is_plan_done then
      content = content
        .. '\n\n🎉 **All steps completed!**\n'
        .. 'Use `@plan action="review" plan_id="'
        .. plan_id
        .. '"` to add review.'
    end

    return { content = content }
  end

  -- Review completed plan
  if action == 'review' then
    local summary = arguments.summary
    local lessons = arguments.lessons
    local issues = arguments.issues

    local plan, err =
      plan_module.review_plan(plan_id, summary, lessons, issues)
    if not plan then
      return { error = err }
    end

    return {
      content = string.format(
        '📝 **Plan Review Completed:** %s\n\n'
          .. 'Summary: %s\n'
          .. 'Lessons learned: %s\n'
          .. 'Issues: %s',
        plan.title,
        summary or 'N/A',
        lessons and table.concat(lessons, ', ') or 'None',
        issues and table.concat(issues, ', ') or 'None'
      ),
    }
  end

  -- Delete plan
  if action == 'delete' then
    plan_module.delete(plan_id)
    return { content = '🗑️ Plan deleted: ' .. plan_id }
  end

  return { error = 'Unknown action: ' .. action }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'plan',
      description = [[
Plan mode for creating, managing, and reviewing task plans.

Actions:
- create: Create new plan with title and optional steps
- show: Show plan details by ID
- list: List all plans (optional status filter)
- add: Add step to existing plan
- next: Start next pending step
- done: Mark current/completed step as done
- review: Review completed plan with summary
- delete: Delete a plan

Examples:
@plan action="create" title="Implement feature X" steps=["Design API", "Write code", "Test"]
@plan action="list" status="in_progress"
@plan action="next" plan_id="plan-20250110-xxxx"
@plan action="done" plan_id="plan-20250110-xxxx" notes="Completed successfully"
@plan action="review" plan_id="plan-20250110-xxxx" summary="Feature implemented" lessons=["Lesson 1"]
      ]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = {
              'create',
              'show',
              'list',
              'add',
              'next',
              'done',
              'review',
              'delete',
            },
            description = 'Plan action to perform',
          },
          title = { type = 'string', description = 'Plan title (for create)' },
          steps = {
            type = 'array',
            items = { type = 'string' },
            description = 'Initial steps (for create)',
          },
          plan_id = { type = 'string', description = 'Plan ID' },
          step_content = {
            type = 'string',
            description = 'Step content (for add)',
          },
          step_id = { type = 'integer', description = 'Step ID (for done)' },
          notes = {
            type = 'string',
            description = 'Notes for step completion',
          },
          status = {
            type = 'string',
            description = 'Filter by status (for list)',
          },
          summary = {
            type = 'string',
            description = 'Plan summary (for review)',
          },
          lessons = {
            type = 'array',
            items = { type = 'string' },
            description = 'Lessons learned (for review)',
          },
          issues = {
            type = 'array',
            items = { type = 'string' },
            description = 'Issues encountered (for review)',
          },
        },
        required = { 'action' },
      },
    },
  }
end

function M.info(arguments, ctx)
  return string.format('Plan: %s', arguments.action)
end

return M

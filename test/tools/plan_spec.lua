-- test/tools/plan_spec.lua
-- Tests for lua/chat/tools/plan.lua (tool handler layer)

local lu = require('luaunit')
local config = require('chat.config')
local working_memory = require('chat.memory.working')

-- Mock working_memory.store to avoid side effects
local original_store = working_memory.store

local function setup_mock()
  working_memory.store = function(_, _, _) end
end

local function teardown_mock()
  working_memory.store = original_store
end

-- Reload both modules so we get fresh instances with empty plans table
local function reload_modules()
  package.loaded['chat.plan'] = nil
  package.loaded['chat.tools.plan'] = nil
  local plan_tool = require('chat.tools.plan')
  local plan_module = require('chat.plan')
  return plan_tool, plan_module
end

TestToolsPlan = {}
local test_storage_dir

function TestToolsPlan:setUp()
  -- Create temporary storage directory
  test_storage_dir = vim.fn.tempname() .. '_plan_tool_test/'
  vim.fn.mkdir(test_storage_dir, 'p')

  config.setup({
    storage_dir = test_storage_dir,
    memory = {
      enable = true,
      storage_dir = test_storage_dir .. 'memory/',
      working = { enable = true },
    },
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })

  setup_mock()
end

function TestToolsPlan:tearDown()
  teardown_mock()

  if test_storage_dir and vim.fn.isdirectory(test_storage_dir) == 1 then
    vim.fn.delete(test_storage_dir, 'rf')
  end

  -- Clean reload for next test
  package.loaded['chat.plan'] = nil
  package.loaded['chat.tools.plan'] = nil
end

-- ── Scheme ─────────────────────────────────────────────────

function TestToolsPlan:testScheme()
  local plan_tool = require('chat.tools.plan')
  local scheme = plan_tool.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'plan')
  lu.assertNotNil(scheme['function'].description)
  lu.assertNotNil(scheme['function'].parameters)

  -- Check required fields
  lu.assertTrue(vim.tbl_contains(scheme['function'].parameters.required, 'action'))

  -- Check action enum
  local actions = scheme['function'].parameters.properties.action.enum
  lu.assertTrue(vim.tbl_contains(actions, 'create'))
  lu.assertTrue(vim.tbl_contains(actions, 'show'))
  lu.assertTrue(vim.tbl_contains(actions, 'list'))
  lu.assertTrue(vim.tbl_contains(actions, 'add'))
  lu.assertTrue(vim.tbl_contains(actions, 'next'))
  lu.assertTrue(vim.tbl_contains(actions, 'done'))
  lu.assertTrue(vim.tbl_contains(actions, 'pause'))
  lu.assertTrue(vim.tbl_contains(actions, 'resume'))
  lu.assertTrue(vim.tbl_contains(actions, 'review'))
  lu.assertTrue(vim.tbl_contains(actions, 'delete'))
  -- New actions
  lu.assertTrue(vim.tbl_contains(actions, 'cancel_step'))
  lu.assertTrue(vim.tbl_contains(actions, 'delete_step'))
  lu.assertTrue(vim.tbl_contains(actions, 'update_step'))
  lu.assertTrue(vim.tbl_contains(actions, 'reorder_steps'))
  lu.assertTrue(vim.tbl_contains(actions, 'update_title'))
  lu.assertTrue(vim.tbl_contains(actions, 'cancel'))
  lu.assertTrue(vim.tbl_contains(actions, 'reopen'))

  -- Check key properties exist
  lu.assertNotNil(scheme['function'].parameters.properties.title)
  lu.assertNotNil(scheme['function'].parameters.properties.steps)
  lu.assertNotNil(scheme['function'].parameters.properties.plan_id)
  lu.assertNotNil(scheme['function'].parameters.properties.step_content)
  lu.assertNotNil(scheme['function'].parameters.properties.step_id)
  lu.assertNotNil(scheme['function'].parameters.properties.notes)
  lu.assertNotNil(scheme['function'].parameters.properties.status)
  lu.assertNotNil(scheme['function'].parameters.properties.summary)
  lu.assertNotNil(scheme['function'].parameters.properties.lessons)
  lu.assertNotNil(scheme['function'].parameters.properties.issues)
  -- New properties
  lu.assertNotNil(scheme['function'].parameters.properties.include_project)
  lu.assertNotNil(scheme['function'].parameters.properties.pause_reason)
  lu.assertNotNil(scheme['function'].parameters.properties.step_ids)
end

-- ── Info ───────────────────────────────────────────────────

function TestToolsPlan:testInfoWithCreate()
  local plan_tool = require('chat.tools.plan')
  local info = plan_tool.info(
    vim.json.encode({ action = 'create', title = 'My Plan' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'create')
  lu.assertStrContains(info, 'My Plan')
end

function TestToolsPlan:testInfoWithPlanId()
  local plan_tool = require('chat.tools.plan')
  local info = plan_tool.info(
    vim.json.encode({ action = 'next', plan_id = 'plan-12345' }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'next')
  lu.assertStrContains(info, 'plan-12345')
end

function TestToolsPlan:testInfoWithInvalidJson()
  local plan_tool = require('chat.tools.plan')
  local info = plan_tool.info('not json', { cwd = vim.fn.getcwd() })
  lu.assertEquals(info, 'Plan')
end

-- ── Create ─────────────────────────────────────────────────

function TestToolsPlan:testCreateWithSteps()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'create',
    title = 'Test Plan',
    steps = { 'Step 1', 'Step 2', 'Step 3' },
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Test Plan')
  lu.assertStrContains(result.content, 'plan-')
  lu.assertStrContains(result.content, 'Steps: 3')
end

function TestToolsPlan:testCreateWithoutSteps()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'create',
    title = 'Empty Plan',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Empty Plan')
  lu.assertStrContains(result.content, 'Steps: 0')
end

function TestToolsPlan:testCreateWithStepsAsString()
  -- Defensive: steps as string should be normalized to array
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'create',
    title = 'String Steps Plan',
    steps = 'Single step as string',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Steps: 1')
end

function TestToolsPlan:testCreateMissingTitle()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'create',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'title is required')
end

function TestToolsPlan:testCreateEmptyTitle()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'create',
    title = '',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'title is required')
end

-- ── List ───────────────────────────────────────────────────

function TestToolsPlan:testListEmpty()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'list',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'No plans found')
end

function TestToolsPlan:testListWithPlans()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- Create two plans
  plan_tool.plan({
    action = 'create',
    title = 'Plan A',
    steps = { 'A1' },
  }, ctx)

  plan_tool.plan({
    action = 'create',
    title = 'Plan B',
    steps = { 'B1', 'B2' },
  }, ctx)

  local result = plan_tool.plan({
    action = 'list',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Plan A')
  lu.assertStrContains(result.content, 'Plan B')
end

function TestToolsPlan:testListWithStatusFilter()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- Create a plan (status: pending)
  plan_tool.plan({
    action = 'create',
    title = 'Pending Plan',
    steps = { 'Step 1' },
  }, ctx)

  -- List with status filter for 'pending'
  local result = plan_tool.plan({
    action = 'list',
    status = 'pending',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Pending Plan')

  -- List with status filter for 'completed' (should be empty)
  local result2 = plan_tool.plan({
    action = 'list',
    status = 'completed',
  }, ctx)

  lu.assertNil(result2.error)
  lu.assertStrContains(result2.content, 'No completed plans')
end

function TestToolsPlan:testListSessionIsolation()
  local plan_tool, _ = reload_modules()
  local ctx_a = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'session-a',
  }
  local ctx_b = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'session-b',
  }

  -- Create plans in different sessions (same project)
  plan_tool.plan({
    action = 'create',
    title = 'Plan A',
    steps = { 'A1' },
  }, ctx_a)

  plan_tool.plan({
    action = 'create',
    title = 'Plan B',
    steps = { 'B1' },
  }, ctx_b)

  -- List in session A should only show Plan A
  local result_a = plan_tool.plan({ action = 'list' }, ctx_a)
  lu.assertNil(result_a.error)
  lu.assertStrContains(result_a.content, 'Plan A')
  lu.assertNotStrContains(result_a.content, 'Plan B')

  -- List in session B should only show Plan B
  local result_b = plan_tool.plan({ action = 'list' }, ctx_b)
  lu.assertNil(result_b.error)
  lu.assertStrContains(result_b.content, 'Plan B')
  lu.assertNotStrContains(result_b.content, 'Plan A')
end

function TestToolsPlan:testListIncludeProject()
  local plan_tool, _ = reload_modules()
  local ctx_a = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'session-a',
  }
  local ctx_b = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'session-b',
  }

  -- Create plans in different sessions (same project)
  plan_tool.plan({
    action = 'create',
    title = 'Plan A',
    steps = { 'A1' },
  }, ctx_a)

  plan_tool.plan({
    action = 'create',
    title = 'Plan B',
    steps = { 'B1' },
  }, ctx_b)

  -- List with include_project in session A should show both
  local result = plan_tool.plan({
    action = 'list',
    include_project = true,
  }, ctx_a)
  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Plan A')
  lu.assertStrContains(result.content, 'Plan B')
  lu.assertStrContains(result.content, 'Current Project')
end

function TestToolsPlan:testListDifferentSessionAndDir()
  local plan_tool, _ = reload_modules()
  local ctx_a = {
    cwd = '/different-project',
    session = 'session-a',
  }
  local ctx_b = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'session-b',
  }

  -- Create plan in different session AND different dir
  plan_tool.plan({
    action = 'create',
    title = 'Other Project Plan',
    steps = { 'X1' },
  }, ctx_a)

  plan_tool.plan({
    action = 'create',
    title = 'My Project Plan',
    steps = { 'M1' },
  }, ctx_b)

  -- List with include_project in session B should NOT show Other Project Plan
  local result = plan_tool.plan({
    action = 'list',
    include_project = true,
  }, ctx_b)
  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'My Project Plan')
  lu.assertNotStrContains(result.content, 'Other Project Plan')
end

-- ── Show ───────────────────────────────────────────────────

function TestToolsPlan:testShowPlan()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- Create a plan
  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Show Test Plan',
    steps = { 'Step A', 'Step B' },
  }, ctx)

  -- Extract plan_id from result content
  local plan_id = create_result.content:match('`plan-[^`]+`')
  lu.assertNotNil(plan_id)
  -- Remove backticks
  plan_id = plan_id:gsub('`', '')

  local result = plan_tool.plan({
    action = 'show',
    plan_id = plan_id,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Show Test Plan')
  lu.assertStrContains(result.content, 'Step A')
  lu.assertStrContains(result.content, 'Step B')
  lu.assertStrContains(result.content, 'pending')
end

function TestToolsPlan:testShowNonExistentPlan()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({
    action = 'show',
    plan_id = 'non-existent-id',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not found')
end

-- ── Add ────────────────────────────────────────────────────

function TestToolsPlan:testAddStep()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- Create a plan
  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Add Step Plan',
    steps = { 'Original Step' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Add a step
  local result = plan_tool.plan({
    action = 'add',
    plan_id = plan_id,
    step_content = 'Added Step',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Added Step')

  -- Verify via show
  local show_result = plan_tool.plan({
    action = 'show',
    plan_id = plan_id,
  }, ctx)
  lu.assertStrContains(show_result.content, 'Added Step')
end

function TestToolsPlan:testAddStepMissingContent()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Test',
    steps = { 'S1' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'add',
    plan_id = plan_id,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'step_content is required')
end

-- ── Next ───────────────────────────────────────────────────

function TestToolsPlan:testNextStep()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Next Test',
    steps = { 'Step 1', 'Step 2' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'next',
    plan_id = plan_id,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Started Step')
  lu.assertStrContains(result.content, 'Step 1')
end

function TestToolsPlan:testNextStepNoPending()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'No Pending',
    steps = { 'Only Step' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Start and complete the only step
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)
  plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
    step_id = 1,
  }, ctx)

  -- Plan is completed after all steps done, next should fail
  local result = plan_tool.plan({
    action = 'next',
    plan_id = plan_id,
  }, ctx)

  lu.assertNotNil(result.error)
  -- After completing all steps, plan is completed
  lu.assertStrContains(result.error, 'completed')
end

-- ── Done ───────────────────────────────────────────────────

function TestToolsPlan:testDoneWithStepId()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Done Test',
    steps = { 'Step 1', 'Step 2' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Start step 1
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)

  -- Complete step 1 with explicit step_id
  local result = plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
    step_id = 1,
    notes = 'Done with notes',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Completed Step')
  lu.assertStrContains(result.content, 'Step 1')
end

function TestToolsPlan:testDoneAutoDetectInProgress()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Auto Done',
    steps = { 'Step 1' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Start step (no step_id in done - should auto-detect)
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)

  local result = plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Completed Step')
end

function TestToolsPlan:testDoneAllCompleted()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'All Done',
    steps = { 'Only Step' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Start and complete the only step
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)
  local result = plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
    step_id = 1,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'All steps completed')
end

function TestToolsPlan:testDoneNoStepInProgress()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'No In Progress',
    steps = { 'Step 1' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Don't start any step, try done without step_id
  local result = plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'No step in progress')
end

-- ── Pause / Resume ─────────────────────────────────────────

function TestToolsPlan:testPauseAndResume()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Pause Test',
    steps = { 'Step 1', 'Step 2' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Start a step to make plan in_progress
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)

  -- Pause
  local pause_result = plan_tool.plan({
    action = 'pause',
    plan_id = plan_id,
    notes = 'Need a break',
  }, ctx)

  lu.assertNil(pause_result.error)
  lu.assertStrContains(pause_result.content, 'paused')
  lu.assertStrContains(pause_result.content, 'Need a break')

  -- Resume
  local resume_result = plan_tool.plan({
    action = 'resume',
    plan_id = plan_id,
  }, ctx)

  lu.assertNil(resume_result.error)
  lu.assertStrContains(resume_result.content, 'resumed')
end

function TestToolsPlan:testNextOnPausedPlan()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Paused Next Test',
    steps = { 'Step 1', 'Step 2' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Start and pause
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)
  plan_tool.plan({ action = 'pause', plan_id = plan_id }, ctx)

  -- Try next on paused plan
  local result = plan_tool.plan({
    action = 'next',
    plan_id = plan_id,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'paused')
end

-- ── Review ─────────────────────────────────────────────────

function TestToolsPlan:testReview()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Review Test',
    steps = { 'Step 1' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Complete the plan
  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)
  plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
    step_id = 1,
  }, ctx)

  -- Review
  local result = plan_tool.plan({
    action = 'review',
    plan_id = plan_id,
    summary = 'Great success',
    lessons = { 'Lesson 1', 'Lesson 2' },
    issues = { 'Issue 1' },
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Review Completed')
  lu.assertStrContains(result.content, 'Great success')
  lu.assertStrContains(result.content, 'Lesson 1')
  lu.assertStrContains(result.content, 'Issue 1')
end

function TestToolsPlan:testReviewWithLessonsAsString()
  -- Defensive: lessons as string should be normalized to array
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'String Lessons',
    steps = { 'Step 1' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = plan_id }, ctx)
  plan_tool.plan({
    action = 'done',
    plan_id = plan_id,
    step_id = 1,
  }, ctx)

  local result = plan_tool.plan({
    action = 'review',
    plan_id = plan_id,
    summary = 'Done',
    lessons = 'Single lesson as string',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Single lesson as string')
end

-- ── Delete ─────────────────────────────────────────────────

function TestToolsPlan:testDelete()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Delete Me',
    steps = { 'Step 1' },
  }, ctx)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'delete',
    plan_id = plan_id,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'deleted')

  -- Verify it's gone
  local show_result = plan_tool.plan({
    action = 'show',
    plan_id = plan_id,
  }, ctx)
  lu.assertNotNil(show_result.error)
end

-- ── Error Cases ────────────────────────────────────────────

function TestToolsPlan:testMissingAction()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  local result = plan_tool.plan({}, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'action is required')
end

function TestToolsPlan:testUnknownAction()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- Provide plan_id so we pass the plan_id check and reach the unknown action fallback
  local result = plan_tool.plan({
    action = 'unknown_action',
    plan_id = 'dummy-id',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Unknown action')
end

function TestToolsPlan:testMissingPlanId()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- Actions that require plan_id (including new ones)
  local actions = {
    'show', 'add', 'next', 'done',
    'cancel_step', 'delete_step', 'update_step', 'reorder_steps',
    'pause', 'resume', 'review',
    'update_title', 'cancel', 'reopen',
    'delete',
  }
  for _, action in ipairs(actions) do
    local result = plan_tool.plan({
      action = action,
    }, ctx)
    lu.assertNotNil(result.error, 'Should error for action: ' .. action)
    lu.assertStrContains(result.error, 'plan_id is required')
  end
end

-- ── Integration: Full Lifecycle ────────────────────────────

function TestToolsPlan:testFullLifecycle()
  local plan_tool, _ = reload_modules()
  local ctx = {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    session = 'test-session',
  }

  -- 1. Create
  local create_result = plan_tool.plan({
    action = 'create',
    title = 'Lifecycle Plan',
    steps = { 'Design', 'Implement', 'Test' },
  }, ctx)
  lu.assertNil(create_result.error)
  local plan_id = create_result.content:match('`plan-[^`]+`'):gsub('`', '')

  -- 2. List should show it
  local list_result = plan_tool.plan({ action = 'list' }, ctx)
  lu.assertStrContains(list_result.content, 'Lifecycle Plan')

  -- 3. Start step 1
  local next1 = plan_tool.plan({
    action = 'next', plan_id = plan_id,
  }, ctx)
  lu.assertStrContains(next1.content, 'Design')

  -- 4. Complete step 1
  local done1 = plan_tool.plan({
    action = 'done', plan_id = plan_id, step_id = 1,
  }, ctx)
  lu.assertStrContains(done1.content, 'Completed Step')

  -- 5. Start step 2
  local next2 = plan_tool.plan({
    action = 'next', plan_id = plan_id,
  }, ctx)
  lu.assertStrContains(next2.content, 'Implement')

  -- 6. Pause
  local pause = plan_tool.plan({
    action = 'pause', plan_id = plan_id,
  }, ctx)
  lu.assertStrContains(pause.content, 'paused')

  -- 7. Resume
  local resume = plan_tool.plan({
    action = 'resume', plan_id = plan_id,
  }, ctx)
  lu.assertStrContains(resume.content, 'resumed')

  -- 8. Complete step 2
  plan_tool.plan({
    action = 'done', plan_id = plan_id, step_id = 2,
  }, ctx)

  -- 9. Start and complete step 3
  plan_tool.plan({
    action = 'next', plan_id = plan_id,
  }, ctx)
  local done3 = plan_tool.plan({
    action = 'done', plan_id = plan_id, step_id = 3,
  }, ctx)
  lu.assertStrContains(done3.content, 'All steps completed')

  -- 10. Review
  local review = plan_tool.plan({
    action = 'review',
    plan_id = plan_id,
    summary = 'All done',
    lessons = { 'Plan early' },
  }, ctx)
  lu.assertStrContains(review.content, 'Review Completed')

  -- 11. Show should show completed status and review
  local show = plan_tool.plan({
    action = 'show', plan_id = plan_id,
  }, ctx)
  lu.assertStrContains(show.content, 'completed')
  lu.assertStrContains(show.content, 'All done')
end

-- ── New Step Operations ────────────────────────────────────

function TestToolsPlan:testCancelStep()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Cancel Step', steps = { 'A', 'B' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)

  local result = plan_tool.plan({
    action = 'cancel_step', plan_id = pid, step_id = 1, notes = 'Skipped',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Cancelled Step')
  lu.assertStrContains(result.content, 'A')
end

function TestToolsPlan:testCancelStepMissingStepId()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Test', steps = { 'A' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'cancel_step', plan_id = pid,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'step_id is required')
end

function TestToolsPlan:testDeleteStep()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Delete Step', steps = { 'A', 'B', 'C' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'delete_step', plan_id = pid, step_id = 2,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'deleted')

  -- Verify step 2 is gone
  local show = plan_tool.plan({ action = 'show', plan_id = pid }, ctx)
  lu.assertNotStrContains(show.content, 'B')
  lu.assertStrContains(show.content, 'A')
  lu.assertStrContains(show.content, 'C')
end

function TestToolsPlan:testUpdateStep()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Update Step', steps = { 'Old content' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'update_step', plan_id = pid, step_id = 1, step_content = 'New content',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Updated Step')
  lu.assertStrContains(result.content, 'New content')
end

function TestToolsPlan:testReorderSteps()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Reorder', steps = { 'A', 'B', 'C' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'reorder_steps', plan_id = pid, step_ids = { 3, 1, 2 },
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'reordered')

  -- Verify order via show
  local show = plan_tool.plan({ action = 'show', plan_id = pid }, ctx)
  -- C should appear before A before B
  local pos_c = show.content:find('C')
  local pos_a = show.content:find('A')
  local pos_b = show.content:find('B')
  lu.assertTrue(pos_c < pos_a, 'C should come before A')
  lu.assertTrue(pos_a < pos_b, 'A should come before B')
end

-- ── New Plan Operations ────────────────────────────────────

function TestToolsPlan:testUpdateTitle()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Old Title',
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'update_title', plan_id = pid, title = 'New Title',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'New Title')
end

function TestToolsPlan:testCancelPlan()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Cancel Me', steps = { 'Step 1' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)

  local result = plan_tool.plan({
    action = 'cancel', plan_id = pid, notes = 'Requirements changed',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'abandoned')
  lu.assertStrContains(result.content, 'Requirements changed')
end

function TestToolsPlan:testCancelCompletedPlanFails()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Done Plan', steps = { 'Step 1' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)
  plan_tool.plan({ action = 'done', plan_id = pid, step_id = 1 }, ctx)

  local result = plan_tool.plan({
    action = 'cancel', plan_id = pid,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'completed')
end

function TestToolsPlan:testReopenPlan()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Reopen Me', steps = { 'A', 'B' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Complete the plan
  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)
  plan_tool.plan({ action = 'done', plan_id = pid, step_id = 1 }, ctx)
  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)
  plan_tool.plan({ action = 'done', plan_id = pid, step_id = 2 }, ctx)

  -- Reopen
  local result = plan_tool.plan({
    action = 'reopen', plan_id = pid,
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'reopened')
  lu.assertStrContains(result.content, 'pending')
end

-- ── pause_reason parameter ─────────────────────────────────

function TestToolsPlan:testPauseWithPauseReason()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Pause Test', steps = { 'A' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)

  local result = plan_tool.plan({
    action = 'pause', plan_id = pid, pause_reason = 'Waiting for API',
  }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'paused')
  lu.assertStrContains(result.content, 'Waiting for API')
end

-- ── Review on non-completed plan fails ─────────────────────

function TestToolsPlan:testReviewNonCompletedFails()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Pending', steps = { 'A' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  local result = plan_tool.plan({
    action = 'review', plan_id = pid, summary = 'Summary',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'completed')
end

-- ── add_step to completed plan fails ───────────────────────

function TestToolsPlan:testAddStepToCompletedFails()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Completed', steps = { 'A' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)
  plan_tool.plan({ action = 'done', plan_id = pid, step_id = 1 }, ctx)

  local result = plan_tool.plan({
    action = 'add', plan_id = pid, step_content = 'New step',
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'completed')
end

-- ── start_next on completed plan fails ─────────────────────

function TestToolsPlan:testNextOnCompletedFails()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Done', steps = { 'A' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)
  plan_tool.plan({ action = 'done', plan_id = pid, step_id = 1 }, ctx)

  local result = plan_tool.plan({
    action = 'next', plan_id = pid,
  }, ctx)

  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'completed')
end

-- ── show with review details ───────────────────────────────

function TestToolsPlan:testShowWithReviewDetails()
  local plan_tool, _ = reload_modules()
  local ctx = { cwd = vim.fs.normalize(vim.fn.getcwd()), session = 's1' }

  local cr = plan_tool.plan({
    action = 'create', title = 'Reviewed Plan', steps = { 'A' },
  }, ctx)
  local pid = cr.content:match('`plan-[^`]+`'):gsub('`', '')

  -- Complete and review
  plan_tool.plan({ action = 'next', plan_id = pid }, ctx)
  plan_tool.plan({ action = 'done', plan_id = pid, step_id = 1 }, ctx)
  plan_tool.plan({
    action = 'review', plan_id = pid,
    summary = 'Great success',
    lessons = { 'Plan early', 'Test often' },
    issues = { 'API was down' },
  }, ctx)

  -- Show should include review details
  local result = plan_tool.plan({ action = 'show', plan_id = pid }, ctx)

  lu.assertNil(result.error)
  lu.assertStrContains(result.content, 'Review:')
  lu.assertStrContains(result.content, 'Great success')
  lu.assertStrContains(result.content, 'Lessons:')
  lu.assertStrContains(result.content, 'Plan early')
  lu.assertStrContains(result.content, 'Issues:')
  lu.assertStrContains(result.content, 'API was down')
end

-- ── info with step_id ─────────────────────────────────────

function TestToolsPlan:testInfoWithStepId()
  local plan_tool = require('chat.tools.plan')
  local info = plan_tool.info(
    vim.json.encode({ action = 'done', plan_id = 'plan-12345', step_id = 3 }),
    { cwd = vim.fn.getcwd() }
  )
  lu.assertStrContains(info, 'done')
  lu.assertStrContains(info, 'plan-12345')
  lu.assertStrContains(info, 'step 3')
end

return TestToolsPlan


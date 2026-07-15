-- test/plan_spec.lua
-- Tests for lua/chat/plan.lua

local lu = require('luaunit')
local config = require('chat.config')
local working_memory = require('chat.memory.working')

-- Mock working_memory
local original_store = working_memory.store
local mock_memory_store_calls = {}

local function setup_mock()
  mock_memory_store_calls = {}
  working_memory.store = function(session, role, content)
    table.insert(mock_memory_store_calls, {
      session = session,
      role = role,
      content = content,
    })
  end
end

local function teardown_mock()
  working_memory.store = original_store
end

TestPlan = {}
local test_storage_dir

function TestPlan:setUp()
  -- Create temporary storage directory
  test_storage_dir = vim.fn.tempname() .. '_plan_test/'
  vim.fn.mkdir(test_storage_dir, 'p')

  -- Setup test config
  config.setup({
    memory = {
      enable = true,
      storage_dir = test_storage_dir,
      working = {
        enable = true,
      },
    },
  })

  -- Setup mock
  setup_mock()
end

function TestPlan:tearDown()
  -- Clean up test directory
  if test_storage_dir and vim.fn.isdirectory(test_storage_dir) == 1 then
    vim.fn.delete(test_storage_dir, 'rf')
  end

  -- Restore mock
  teardown_mock()
end

function TestPlan:testCreatePlan()
  -- Reset plans for clean test
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Test creating a plan with steps
  local p = plan.create('Test Plan', { 'Step 1', 'Step 2', 'Step 3' })

  lu.assertNotNil(p, 'Plan should not be nil')
  lu.assertTrue(vim.startswith(p.id, 'plan-'), 'ID should start with plan-')
  lu.assertEquals(p.title, 'Test Plan', 'Title should match')
  lu.assertEquals(p.status, 'pending', 'Initial status should be pending')
  lu.assertEquals(#p.steps, 3, 'Should have 3 steps')

  -- Verify steps
  lu.assertEquals(p.steps[1].content, 'Step 1')
  lu.assertEquals(p.steps[1].status, 'pending')
  lu.assertEquals(p.steps[2].content, 'Step 2')
  lu.assertEquals(p.steps[3].content, 'Step 3')

  -- Verify working memory was called
  lu.assertTrue(
    #mock_memory_store_calls > 0,
    'Should call working_memory.store'
  )
end

function TestPlan:testCreatePlanWithNoSteps()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Empty Plan', {})

  lu.assertNotNil(p)
  lu.assertEquals(#p.steps, 0, 'Should have 0 steps')
end

function TestPlan:testGetPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local created = plan.create('Get Test', { 'Step 1' })
  local retrieved = plan.get(created.id)

  lu.assertNotNil(retrieved, 'Should retrieve plan')
  lu.assertEquals(retrieved.id, created.id, 'IDs should match')
  lu.assertEquals(retrieved.title, 'Get Test')

  -- Test non-existent plan
  local not_found = plan.get('non-existent-id')
  lu.assertNil(not_found, 'Should return nil for non-existent plan')
end

function TestPlan:testListPlans()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Create multiple plans
  plan.create('Plan 1', {})
  plan.create('Plan 2', {})
  plan.create('Plan 3', {})

  local all = plan.list()
  lu.assertEquals(#all, 3, 'Should list all plans')

  -- Test with status filter
  local p1 = plan.create('Pending Plan', {})
  lu.assertEquals(p1.status, 'pending')

  local pending = plan.list('pending')
  lu.assertTrue(#pending >= 1, 'Should have at least 1 pending plan')
end

function TestPlan:testListBySession()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Create plans with different sessions (same project)
  plan.create('Session A Plan', {}, { working_dir = '/project1', session = 'session-a' })
  plan.create('Session B Plan', {}, { working_dir = '/project1', session = 'session-b' })

  -- List by session A only
  local result = plan.list(nil, '/project1', 'session-a')
  lu.assertEquals(#result, 1, 'Should only show session A plans')
  lu.assertEquals(result[1].title, 'Session A Plan')

  -- List by session B only
  result = plan.list(nil, '/project1', 'session-b')
  lu.assertEquals(#result, 1, 'Should only show session B plans')
  lu.assertEquals(result[1].title, 'Session B Plan')
end

function TestPlan:testListIncludeProject()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Create plans with different sessions but same project
  plan.create('Session A Plan', {}, { working_dir = '/project1', session = 'session-a' })
  plan.create('Session B Plan', {}, { working_dir = '/project1', session = 'session-b' })

  -- List with include_project=true should show both plans from same project
  local result = plan.list(nil, '/project1', 'session-a', true)
  lu.assertEquals(#result, 2, 'Should show both plans from same project')

  -- List without include_project should only show current session
  result = plan.list(nil, '/project1', 'session-a')
  lu.assertEquals(#result, 1, 'Should only show current session plan')
  lu.assertEquals(result[1].title, 'Session A Plan')
end

function TestPlan:testListDifferentSessionAndDir()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Plan from different session AND different dir
  plan.create('Other Plan', {}, { working_dir = '/other-project', session = 'other-session' })
  plan.create('My Plan', {}, { working_dir = '/my-project', session = 'my-session' })

  -- Even with include_project, should NOT show plans from different dir AND session
  local result = plan.list(nil, '/my-project', 'my-session', true)
  lu.assertEquals(#result, 1, 'Should not mix different session AND different dir')
  lu.assertEquals(result[1].title, 'My Plan')
end

function TestPlan:testAddStep()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Add Step Test', { 'Initial Step' })
  local initial_count = #p.steps

  local step = plan.add_step(p.id, 'New Step')

  lu.assertNotNil(step, 'Should return new step')
  lu.assertEquals(step.content, 'New Step')
  lu.assertEquals(step.status, 'pending')

  -- Verify step was added
  local updated = plan.get(p.id)
  lu.assertEquals(#updated.steps, initial_count + 1)

  -- Test adding step to non-existent plan
  local not_found = plan.add_step('non-existent', 'Step')
  lu.assertNil(not_found, 'Should return nil for non-existent plan')
end

function TestPlan:testStartNext()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Start Next Test', { 'Step 1', 'Step 2' })
  lu.assertEquals(p.status, 'pending')

  -- Start first step
  local step1 = plan.start_next(p.id)

  lu.assertNotNil(step1, 'Should return step')
  lu.assertEquals(step1.content, 'Step 1')
  lu.assertEquals(step1.status, 'in_progress')
  lu.assertNotNil(step1.started_at)

  -- Verify plan status changed
  local updated = plan.get(p.id)
  lu.assertEquals(updated.status, 'in_progress')

  -- Start next step (should be step 2 now)
  plan.complete_step(p.id, step1.id, 'Done with step 1')
  local step2 = plan.start_next(p.id)

  lu.assertNotNil(step2)
  lu.assertEquals(step2.content, 'Step 2')
end

function TestPlan:testStartNextWithNoPendingSteps()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('No Pending Test', { 'Step 1' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1, 'Done')

  -- All steps completed, should return nil
  local step = plan.start_next(p.id)
  lu.assertNil(step, 'Should return nil when no pending steps')
end

function TestPlan:testCompleteStep()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Complete Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)

  local step = plan.complete_step(p.id, 1, 'Completed successfully')

  lu.assertNotNil(step, 'Should return completed step')
  lu.assertEquals(step.status, 'completed')
  lu.assertEquals(step.notes, 'Completed successfully')
  lu.assertNotNil(step.completed_at)

  -- Verify plan not yet completed (still has step 2)
  local updated = plan.get(p.id)
  lu.assertNotEquals(updated.status, 'completed')

  -- Complete last step
  plan.start_next(p.id)
  local step2 = plan.complete_step(p.id, 2, 'Done')

  -- Verify plan is now completed
  updated = plan.get(p.id)
  lu.assertEquals(updated.status, 'completed')
  lu.assertNotNil(updated.review.completed_at)
end

function TestPlan:testCompleteStepNotFound()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Not Found Test', { 'Step 1' })

  -- Try to complete non-existent step
  local result, err = plan.complete_step(p.id, 999, 'Notes')
  lu.assertNil(result, 'Should return nil')
  lu.assertEquals(err, 'Step not found', 'Should return error message')
end

function TestPlan:testReviewPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Review Test', { 'Step 1' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1, 'Done')

  local reviewed = plan.review_plan(
    p.id,
    'Plan completed successfully',
    { 'Lesson 1', 'Lesson 2' },
    { 'Issue 1' }
  )

  lu.assertNotNil(reviewed)
  lu.assertEquals(reviewed.review.summary, 'Plan completed successfully')
  lu.assertEquals(#reviewed.review.lessons_learned, 2)
  lu.assertEquals(#reviewed.review.issues_encountered, 1)
  lu.assertEquals(reviewed.status, 'completed')
end

function TestPlan:testDeletePlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Delete Test', {})

  -- Verify plan exists
  local retrieved = plan.get(p.id)
  lu.assertNotNil(retrieved, 'Plan should exist')

  -- Delete plan
  plan.delete(p.id)

  -- Verify plan is deleted
  local deleted = plan.get(p.id)
  lu.assertNil(deleted, 'Plan should be deleted')
end

function TestPlan:testPlanPersistence()
  -- Test that plans are saved and loaded correctly
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Create a plan
  local p1 = plan.create('Persistence Test', { 'Step 1' })
  local plan_id = p1.id

  -- Add a step
  plan.add_step(plan_id, 'Step 2')

  -- Reload the module (simulates restart)
  package.loaded['chat.plan'] = nil
  local plan_reloaded = require('chat.plan')

  -- Verify data persisted
  local retrieved = plan_reloaded.get(plan_id)
  lu.assertNotNil(retrieved, 'Plan should persist after reload')
  lu.assertEquals(retrieved.title, 'Persistence Test')
  lu.assertEquals(#retrieved.steps, 2, 'Should have 2 steps')
end

-- ── ID Collision ───────────────────────────────────────────

function TestPlan:testIdNoCollision()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Create many plans and verify all IDs are unique
  local ids = {}
  for i = 1, 50 do
    local p = plan.create('Plan ' .. i, {})
    lu.assertNotNil(p.id)
    lu.assertIsNil(ids[p.id], 'ID should be unique: ' .. p.id)
    ids[p.id] = true
  end
end

-- ── add_step Status ────────────────────────────────────────

function TestPlan:testAddStepDoesNotChangePendingStatus()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Pending Test', { 'Step 1' })
  lu.assertEquals(p.status, 'pending')

  plan.add_step(p.id, 'Step 2')

  local updated = plan.get(p.id)
  lu.assertEquals(updated.status, 'pending', 'Plan should stay pending after add_step')
end

function TestPlan:testAddStepToCompletedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Completed Plan', { 'Step 1' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)

  lu.assertEquals(p.status, 'completed')

  local step, err = plan.add_step(p.id, 'New Step')
  lu.assertNil(step, 'Should not add step to completed plan')
  lu.assertStrContains(err, 'completed')
end

function TestPlan:testAddStepToAbandonedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Abandoned Plan', { 'Step 1' })
  plan.cancel(p.id, 'Not needed')

  local step, err = plan.add_step(p.id, 'New Step')
  lu.assertNil(step, 'Should not add step to abandoned plan')
  lu.assertStrContains(err, 'abandoned')
end

-- ── complete_step Status Checks ────────────────────────────

function TestPlan:testCompleteStepAlreadyCompleted()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Use multi-step plan so plan stays in_progress after completing step 1
  local p = plan.create('Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)

  -- Plan is still in_progress (step 2 pending), so step-level check fires
  local step, err = plan.complete_step(p.id, 1)
  lu.assertNil(step, 'Should not re-complete a completed step')
  lu.assertEquals(err, 'Step is already completed')
end

function TestPlan:testCompleteStepCancelled()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.cancel_step(p.id, 1, 'Not needed')

  local step, err = plan.complete_step(p.id, 1)
  lu.assertNil(step, 'Should not complete a cancelled step')
  lu.assertEquals(err, 'Cannot complete a cancelled step')
end

function TestPlan:testStepUpdatedAt()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('UpdatedAt Test', { 'Step 1' })
  plan.start_next(p.id)

  local step = plan.complete_step(p.id, 1, 'Done')
  lu.assertNotNil(step.updated_at, 'step.updated_at should be set after complete')
end

-- ── cancel_step ────────────────────────────────────────────

function TestPlan:testCancelStep()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Cancel Step Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)

  local step = plan.cancel_step(p.id, 1, 'No longer needed')

  lu.assertNotNil(step, 'Should return cancelled step')
  lu.assertEquals(step.status, 'cancelled')
  lu.assertEquals(step.notes, 'No longer needed')
  lu.assertNotNil(step.completed_at)
  lu.assertNotNil(step.updated_at)
end

function TestPlan:testCancelStepAlreadyCompleted()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Use multi-step plan so plan stays in_progress after completing step 1
  local p = plan.create('Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)

  local step, err = plan.cancel_step(p.id, 1)
  lu.assertNil(step, 'Should not cancel a completed step')
  lu.assertEquals(err, 'Cannot cancel a completed step')
end

function TestPlan:testCancelStepAlreadyCancelled()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.cancel_step(p.id, 1)

  local step, err = plan.cancel_step(p.id, 1)
  lu.assertNil(step, 'Should not re-cancel')
  lu.assertEquals(err, 'Step is already cancelled')
end

function TestPlan:testAllDoneWithCancelledSteps()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Mixed Done Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)
  plan.cancel_step(p.id, 2, 'Skipped')

  -- Plan should be completed since all steps are done (completed or cancelled)
  local updated = plan.get(p.id)
  lu.assertEquals(updated.status, 'completed', 'Plan should complete when all steps are done')
  lu.assertNotNil(updated.review.completed_at)
end

-- ── delete_step ────────────────────────────────────────────

function TestPlan:testDeleteStep()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Delete Step Test', { 'Step 1', 'Step 2', 'Step 3' })

  local result, err = plan.delete_step(p.id, 2)
  lu.assertNotNil(result, 'Should return updated plan')
  lu.assertNil(err)

  local updated = plan.get(p.id)
  lu.assertEquals(#updated.steps, 2, 'Should have 2 steps after deletion')
  lu.assertEquals(updated.steps[1].content, 'Step 1')
  lu.assertEquals(updated.steps[2].content, 'Step 3')
end

function TestPlan:testDeleteStepNotFound()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1' })

  local result, err = plan.delete_step(p.id, 999)
  lu.assertNil(result)
  lu.assertEquals(err, 'Step not found')
end

-- ── update_step ────────────────────────────────────────────

function TestPlan:testUpdateStep()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Update Step Test', { 'Original content' })

  local step = plan.update_step(p.id, 1, 'Updated content')

  lu.assertNotNil(step)
  lu.assertEquals(step.content, 'Updated content')
  lu.assertNotNil(step.updated_at)

  local updated = plan.get(p.id)
  lu.assertEquals(updated.steps[1].content, 'Updated content')
end

function TestPlan:testUpdateStepNotFound()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1' })

  local step, err = plan.update_step(p.id, 999, 'New content')
  lu.assertNil(step)
  lu.assertEquals(err, 'Step not found')
end

-- ── reorder_steps ──────────────────────────────────────────

function TestPlan:testReorderSteps()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Reorder Test', { 'A', 'B', 'C' })

  local result = plan.reorder_steps(p.id, { 3, 1, 2 })
  lu.assertNotNil(result)

  local updated = plan.get(p.id)
  lu.assertEquals(updated.steps[1].content, 'C')
  lu.assertEquals(updated.steps[2].content, 'A')
  lu.assertEquals(updated.steps[3].content, 'B')
end

function TestPlan:testReorderStepsCountMismatch()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'A', 'B', 'C' })

  local result, err = plan.reorder_steps(p.id, { 1, 2 })
  lu.assertNil(result)
  lu.assertEquals(err, 'Step count mismatch')
end

function TestPlan:testReorderStepsInvalidId()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'A', 'B' })

  local result, err = plan.reorder_steps(p.id, { 1, 999 })
  lu.assertNil(result)
  lu.assertStrContains(err, 'Step not found')
end

-- ── update_title ───────────────────────────────────────────

function TestPlan:testUpdateTitle()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Old Title', {})

  local result = plan.update_title(p.id, 'New Title')
  lu.assertNotNil(result)
  lu.assertEquals(result.title, 'New Title')

  local updated = plan.get(p.id)
  lu.assertEquals(updated.title, 'New Title')
end

function TestPlan:testUpdateTitleEmpty()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Title', {})

  local result, err = plan.update_title(p.id, '')
  lu.assertNil(result)
  lu.assertEquals(err, 'Title is required')
end

-- ── cancel (abandon) plan ──────────────────────────────────

function TestPlan:testCancelPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Cancel Plan Test', { 'Step 1' })
  plan.start_next(p.id)

  local result = plan.cancel(p.id, 'Requirements changed')
  lu.assertNotNil(result)
  lu.assertEquals(result.status, 'abandoned')
  lu.assertEquals(result.pause_reason, 'Requirements changed')
end

function TestPlan:testCancelPendingPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Pending Cancel', {})

  local result = plan.cancel(p.id, 'Never started')
  lu.assertNotNil(result)
  lu.assertEquals(result.status, 'abandoned')
end

function TestPlan:testCancelCompletedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)

  local result, err = plan.cancel(p.id)
  lu.assertNil(result)
  lu.assertEquals(err, 'Cannot cancel a completed plan')
end

function TestPlan:testCancelAlreadyAbandoned()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', {})
  plan.cancel(p.id, 'First cancel')

  local result, err = plan.cancel(p.id, 'Second cancel')
  lu.assertNil(result)
  lu.assertEquals(err, 'Plan is already abandoned')
end

-- ── reopen ─────────────────────────────────────────────────

function TestPlan:testReopenCompletedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Reopen Test', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)
  plan.start_next(p.id)
  plan.complete_step(p.id, 2)
  lu.assertEquals(plan.get(p.id).status, 'completed')

  local result = plan.reopen(p.id)
  lu.assertNotNil(result)
  lu.assertEquals(result.status, 'pending', 'Should be pending when all steps completed')
  lu.assertNil(result.review.completed_at, 'review.completed_at should be cleared')
end

function TestPlan:testReopenAbandonedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Reopen Abandoned', { 'Step 1', 'Step 2' })
  plan.start_next(p.id)
  plan.cancel(p.id, 'Not needed')

  local result = plan.reopen(p.id)
  lu.assertNotNil(result)
  lu.assertEquals(result.status, 'in_progress', 'Should be in_progress when has pending steps')
end

function TestPlan:testReopenNonTerminalPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1' })

  local result, err = plan.reopen(p.id)
  lu.assertNil(result)
  lu.assertStrContains(err, 'Only completed or abandoned')
end

-- ── review_plan Status Check ───────────────────────────────

function TestPlan:testReviewPlanRequiresCompleted()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Review Test', { 'Step 1' })

  local result, err = plan.review_plan(p.id, 'Summary')
  lu.assertNil(result, 'Should not review a pending plan')
  lu.assertStrContains(err, 'Only completed or abandoned')
end

function TestPlan:testReviewPlanOnAbandoned()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Review Abandoned', { 'Step 1' })
  plan.cancel(p.id, 'Not needed')

  local result = plan.review_plan(
    p.id,
    'Abandoned summary',
    { 'Lesson: plan better' },
    { 'Issue: bad requirements' }
  )

  lu.assertNotNil(result, 'Should be able to review abandoned plan')
  lu.assertEquals(result.review.summary, 'Abandoned summary')
  lu.assertEquals(result.status, 'abandoned', 'Status should stay abandoned after review')
end

-- ── start_next on terminal plans ───────────────────────────

function TestPlan:testStartNextOnCompletedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1' })
  plan.start_next(p.id)
  plan.complete_step(p.id, 1)

  local step, err = plan.start_next(p.id)
  lu.assertNil(step)
  lu.assertStrContains(err, 'completed')
  lu.assertStrContains(err, 'reopen')
end

function TestPlan:testStartNextOnAbandonedPlan()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p = plan.create('Test', { 'Step 1' })
  plan.cancel(p.id, 'Not needed')

  local step, err = plan.start_next(p.id)
  lu.assertNil(step)
  lu.assertStrContains(err, 'abandoned')
  lu.assertStrContains(err, 'reopen')
end

-- ── list sorting ───────────────────────────────────────────

function TestPlan:testListSorted()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p1 = plan.create('Oldest', {})
  p1.created_at = 1000

  local p2 = plan.create('Newest', {})
  p2.created_at = 3000

  local p3 = plan.create('Middle', {})
  p3.created_at = 2000

  local all = plan.list()
  lu.assertEquals(#all, 3)
  lu.assertEquals(all[1].title, 'Newest', 'Newest should be first')
  lu.assertEquals(all[2].title, 'Middle', 'Middle should be second')
  lu.assertEquals(all[3].title, 'Oldest', 'Oldest should be last')
end

function TestPlan:testListDoesNotMutateOriginal()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  local p1 = plan.create('First', {})
  local p2 = plan.create('Second', {})

  -- Call list (which sorts a copy)
  local sorted = plan.list()

  -- Original order should be preserved (insertion order)
  -- We can't directly access the internal plans table, but we can verify
  -- that calling list again gives consistent results
  local sorted2 = plan.list()
  lu.assertEquals(sorted2[1].title, sorted[1].title)
  lu.assertEquals(sorted2[2].title, sorted[2].title)
end

-- ── load validation ────────────────────────────────────────

function TestPlan:testLoadValidation()
  package.loaded['chat.plan'] = nil
  local plan = require('chat.plan')

  -- Create a plan and save
  local p = plan.create('Validation Test', { 'Step 1' })

  -- Manually write a minimal/old-format JSON to test migration
  local path = config.config.memory.storage_dir .. 'plans.json'
  local minimal_data = {
    {
      id = 'plan-old-0001',
      title = 'Old Plan',
      created_at = os.time(),
      updated_at = os.time(),
      status = 'pending',
      steps = {
        { id = 1, content = 'Old Step', created_at = os.time() },
      },
      -- Missing: context, review, next_step_id, step.notes, step.status
    },
  }

  local file = io.open(path, 'w')
  file:write(vim.json.encode(minimal_data))
  file:close()

  -- Reload module to trigger load
  package.loaded['chat.plan'] = nil
  local plan_reloaded = require('chat.plan')

  -- Access the plan (triggers lazy load)
  local loaded = plan_reloaded.get('plan-old-0001')
  lu.assertNotNil(loaded, 'Old plan should be loaded')
  lu.assertNotNil(loaded.context, 'context should be defaulted')
  lu.assertNotNil(loaded.context.working_dir, 'working_dir should be defaulted')
  lu.assertNotNil(loaded.review, 'review should be defaulted')
  lu.assertEquals(loaded.review.summary, '', 'summary should be empty string')
  lu.assertEquals(#loaded.review.lessons_learned, 0, 'lessons should be empty array')
  lu.assertEquals(loaded.next_step_id, 2, 'next_step_id should be calculated')
  lu.assertEquals(loaded.steps[1].notes, '', 'step.notes should be defaulted')
  lu.assertEquals(loaded.steps[1].status, 'pending', 'step.status should be defaulted')
end

return TestPlan

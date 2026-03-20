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

return TestPlan

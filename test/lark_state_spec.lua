-- Coverage for lua/chat/integrations/lark/state.lua.
--
-- The dedup cache guards messages that were already answered. Its two
-- properties are both load-bearing:
--
--   * the cap keeps the *newest* ids (a `pairs()`-ordered cap keeps an
--     arbitrary subset, so recently answered messages come through again
--     after a restart),
--   * the in-memory cache is trimmed too (a long-running Neovim would
--     otherwise grow one entry per message ever seen).
local lu = require('luaunit')

local state_module = require('chat.integrations.lark.state')

TestLarkState = {}

local function temp_path()
  local dir = vim.fn.tempname() .. '_lark_state_test'
  vim.fn.mkdir(dir, 'p')
  return dir .. '/lark.json', dir
end

----------------------------------------------------------------------------
-- remember / trim
----------------------------------------------------------------------------

function TestLarkState:test_remember_processed_keeps_newest_ids()
  local state = state_module.new()
  state.max_processed_cache = 3

  for index = 1, 5 do
    state_module.remember_processed(state, 'om_' .. index)
  end

  -- Newest three survive, the two oldest were evicted.
  lu.assertNil(state.processed_ids.om_1, 'oldest id evicted')
  lu.assertNil(state.processed_ids.om_2, 'second oldest evicted')
  lu.assertTrue(state.processed_ids.om_3)
  lu.assertTrue(state.processed_ids.om_4)
  lu.assertTrue(state.processed_ids.om_5)

  lu.assertEquals({ 'om_3', 'om_4', 'om_5' }, state.processed_order)
end

function TestLarkState:test_remember_processed_reports_duplicates()
  local state = state_module.new()

  lu.assertTrue(state_module.remember_processed(state, 'om_a'), 'first sight')
  lu.assertFalse(state_module.remember_processed(state, 'om_a'), 'duplicate')
  -- A duplicate must not be appended again, or it would be evicted after
  -- `cap` further messages even though it is the most recent one.
  lu.assertEquals({ 'om_a' }, state.processed_order)

  lu.assertFalse(state_module.remember_processed(state, nil), 'nil id')
  lu.assertFalse(state_module.remember_processed(state, ''), 'empty id')
end

function TestLarkState:test_memory_stays_bounded()
  -- The cache must be trimmed in memory, not only in the serialized copy.
  local state = state_module.new()
  state.max_processed_cache = 10

  for index = 1, 500 do
    state_module.remember_processed(state, 'om_' .. index)
  end

  lu.assertEquals(10, vim.tbl_count(state.processed_ids))
  lu.assertEquals(10, #state.processed_order)
  lu.assertTrue(state.processed_ids.om_500, 'newest id kept')
  lu.assertNil(state.processed_ids.om_1, 'oldest id dropped')
end

----------------------------------------------------------------------------
-- file round-trip
----------------------------------------------------------------------------

function TestLarkState:test_save_persists_newest_ids_only()
  local state = state_module.new()
  state.max_processed_cache = 5
  state.session = 'sess-1'

  for index = 1, 20 do
    state_module.remember_processed(state, 'om_' .. index)
  end

  local path, dir = temp_path()
  lu.assertTrue(state_module.save(state, path), 'state written')

  local loaded_state = state_module.new()
  lu.assertTrue(state_module.load(loaded_state, path), 'state read back')

  -- Every persisted id is one of the five newest, so an already answered
  -- message from the last round can not be answered twice after a restart.
  for id in pairs(loaded_state.processed_ids) do
    local index = tonumber(id:match('om_(%d+)'))
    lu.assertTrue(index >= 16, 'only recent ids are persisted, got ' .. id)
  end
  lu.assertTrue(loaded_state.processed_ids.om_20, 'newest id persisted')

  vim.fn.delete(dir, 'rf')
end

function TestLarkState:test_load_bounds_and_rebuilds_order()
  -- A state file with more ids than the cap (e.g. written by an older build
  -- with a larger cap) must load into a bounded cache in an order that lets
  -- later evictions work.
  local path, dir = temp_path()

  local ids = {}
  for index = 1, 130 do
    ids['om_' .. index] = true
  end
  vim.fn.writefile({ vim.json.encode({ processed_ids = ids, session = 's' }) }, path)

  local state = state_module.new()
  lu.assertTrue(state_module.load(state, path), 'state read back')

  lu.assertTrue(vim.tbl_count(state.processed_ids) <= 100, 'cache capped on load')
  lu.assertEquals(
    vim.tbl_count(state.processed_ids),
    #state.processed_order,
    'the order list mirrors the map'
  )

  -- A newly remembered id evicts the loaded head, keeping the cache bounded.
  state_module.remember_processed(state, 'om_new')
  lu.assertTrue(state.processed_ids.om_new)
  lu.assertTrue(vim.tbl_count(state.processed_ids) <= 100)

  vim.fn.delete(dir, 'rf')
end

function TestLarkState:test_roundtrip_preserves_cursor_and_session()
  local state = state_module.new()
  state.session = 'sess-keep'
  state.last_message_time = '1700000005000'
  state.containers.oc_main = {
    chat_type = 'group',
    last_seen_time = '1700000005000',
    session = 'sess-keep',
  }

  local path, dir = temp_path()
  lu.assertTrue(state_module.save(state, path))

  local loaded_state = state_module.new()
  lu.assertTrue(state_module.load(loaded_state, path))

  lu.assertEquals('sess-keep', loaded_state.session)
  lu.assertEquals('1700000005000', loaded_state.last_message_time)
  lu.assertEquals(
    '1700000005000',
    loaded_state.containers.oc_main.last_seen_time
  )

  vim.fn.delete(dir, 'rf')
end

function TestLarkState:test_reset_cursors_to_now_moves_every_container()
  local state = state_module.new()
  state.last_message_time = '1700000005000'
  state.containers.oc_main = { chat_type = 'group', last_seen_time = '1700000005000' }
  state.containers.oc_p2p = { chat_type = 'p2p', last_seen_time = '1700000005000' }

  local before = os.time()
  local cursor = state_module.reset_cursors_to_now(state)

  lu.assertEquals(cursor, state.last_message_time)
  lu.assertEquals(cursor, state.containers.oc_main.last_seen_time)
  lu.assertEquals(cursor, state.containers.oc_p2p.last_seen_time)
  lu.assertTrue(tonumber(cursor) >= before * 1000)
end


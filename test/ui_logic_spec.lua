-- Coverage for lua/chat/{formatter,preview,context,queue,spinners}.lua
-- and lua/chat/sessions/nudge.lua
local lu = require('luaunit')
local config = require('chat.config')

local formatter = require('chat.formatter')
local preview = require('chat.preview')
local context = require('chat.context')
local queue = require('chat.queue')

local real_windows = package.loaded['chat.windows'] or require('chat.windows')
local real_sessions = package.loaded['chat.sessions'] or require('chat.sessions')
local real_protocol = package.loaded['chat.protocol']
if not real_protocol then
  real_protocol = require('chat.protocol')
end

local function wait_schedule(ms)
  vim.wait(ms or 200, function()
    return false
  end, 20)
end

TestFormatter = {}

function TestFormatter:test_user_message()
  local lines = formatter.generate_message({
    role = 'user',
    content = 'line1\nline2',
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '👤 You: line1')
  lu.assertEquals(lines[2], 'line2')
  lu.assertEquals(lines[#lines], '')
end

function TestFormatter:test_assistant_message()
  local lines = formatter.generate_message({
    role = 'assistant',
    content = 'hello\nworld',
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '🤖 Bot:')
  lu.assertEquals(lines[3], 'hello')
  lu.assertEquals(lines[4], 'world')
end

function TestFormatter:test_assistant_with_reasoning()
  local lines = formatter.generate_message({
    role = 'assistant',
    reasoning_content = 'hmm\nlet me think',
    content = 'answer',
    created = os.time(),
  })
  lu.assertStrContains(lines[1], 'thinking ...')
  lu.assertEquals(lines[3], '> hmm')
  lu.assertEquals(lines[4], '> let me think')
  -- content follows after blank line
  lu.assertEquals(lines[6], 'answer')
end

function TestFormatter:test_assistant_tool_calls()
  local sid = real_sessions.new()
  local lines = formatter.generate_message({
    role = 'assistant',
    content = 'using tools',
    tool_calls = {
      {
        id = 't1',
        ['function'] = { name = 'get_time', arguments = '{}' },
      },
      -- nil entries are skipped via goto continue
    },
    created = os.time(),
  }, sid)
  local joined = table.concat(lines, '\n')
  lu.assertStrContains(joined, '🔧 Executing tool')
  lu.assertStrContains(joined, 'get_time')
end

function TestFormatter:test_assistant_tool_call_nil_entry()
  local sid = real_sessions.new()
  local calls = {}
  calls[1] = {
    id = 't1',
    ['function'] = { name = 'get_time', arguments = '{}' },
  }
  -- sparse array with nil hole
  local lines = formatter.generate_message({
    role = 'assistant',
    tool_calls = { calls[1], nil },
    created = os.time(),
  }, sid)
  lu.assertStrContains(table.concat(lines, '\n'), 'get_time')
end

function TestFormatter:test_tool_error_message()
  local lines = formatter.generate_message({
    role = 'tool',
    tool_call_state = { error = 'boom\nline2' },
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '❌ : Tool Error: boom')
  -- continuation lines are indented to align with the base prefix
  lu.assertStrContains(lines[2], 'line2')
end

function TestFormatter:test_tool_success_message()
  local lines = formatter.generate_message({
    role = 'tool',
    tool_call_state = { name = 'read_file' },
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '✅ Tool execution complete: read_file')
end

function TestFormatter:test_tool_success_no_state()
  local lines = formatter.generate_message({
    role = 'tool',
    created = os.time(),
  })
  lu.assertStrContains(lines[1], 'Tool execution complete: ')
end

function TestFormatter:test_plain_content_fallback()
  local lines = formatter.generate_message({
    role = 'custom-role',
    content = 'plain\ntext',
    created = os.time(),
  })
  lu.assertEquals(lines, { 'plain', 'text' })
end

function TestFormatter:test_on_complete_without_usage()
  -- role nil: completion notices bypass the assistant branch
  local lines = formatter.generate_message({
    on_complete = true,
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '✅ Completed')
  lu.assertNil(lines[1]:find('Tokens'))
end

function TestFormatter:test_on_complete_with_usage()
  local lines = formatter.generate_message({
    on_complete = true,
    usage = {
      total_tokens = 1500,
      prompt_tokens = 1000,
      completion_tokens = 500,
    },
    created = os.time(),
  })
  lu.assertStrContains(lines[1], 'Tokens: 1.5K (1.0K↑/500↓)')
end

function TestFormatter:test_on_complete_with_cached_tokens()
  local lines = formatter.generate_message({
    on_complete = true,
    usage = {
      total_tokens = 1000,
      prompt_tokens = 1000,
      completion_tokens = 0,
      prompt_tokens_details = { cached_tokens = 400 },
    },
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '💾 40%')
end

function TestFormatter:test_error_message()
  local lines = formatter.generate_message({
    role = nil,
    error = 'oops\nsecond line',
    created = os.time(),
  })
  lu.assertStrContains(lines[1], '❌ : oops')
  lu.assertStrContains(lines[2], 'second line')
end

function TestFormatter:test_empty_message()
  -- assistant with no content still renders header + blank line
  local lines = formatter.generate_message({ role = 'assistant' }, 'x')
  lu.assertEquals(#lines, 2)
  lu.assertEquals(lines[2], '')
end

function TestFormatter:test_generate_buffer()
  local lines = formatter.generate_buffer({
    { role = 'user', content = 'q', created = os.time() },
    { role = 'assistant', content = 'a', created = os.time() },
  }, 'x')
  lu.assertTrue(#lines >= 4)
end

function TestFormatter:test_generate_buffer_with_map()
  local messages = {
    { role = 'user', content = 'q1\nq2', created = os.time() },
    { role = 'assistant', content = 'a', created = os.time() },
  }
  local lines, map = formatter.generate_buffer_with_map(messages, 'x')
  lu.assertEquals(#map, 2)
  lu.assertEquals(map[1].start_line, 1)
  lu.assertEquals(map[1].end_line, 3, 'user msg = header + content + blank')
  lu.assertEquals(map[2].start_line, 4)
  lu.assertEquals(map[2].end_line, #lines)
end

TestPreview = {}

function TestPreview:test_generate_html_minimal()
  local html = preview.generate_html({
    id = 'sess-1',
    provider = 'openai',
    model = 'gpt-x',
    cwd = '/tmp/x',
    prompt = 'be <helpful>',
    messages = {},
  })
  lu.assertStrContains(html, '<!DOCTYPE html>')
  lu.assertStrContains(html, 'sess-1')
  lu.assertStrContains(html, 'be &lt;helpful&gt;')
end

function TestPreview:test_generate_html_defaults()
  local html = preview.generate_html({})
  lu.assertStrContains(html, 'unknown')
end

function TestPreview:test_generate_html_message_roles()
  local html = preview.generate_html({
    id = 's',
    messages = {
      { role = 'user', content = 'hi', created = os.time() },
      { role = 'assistant', content = 'hello', created = os.time() },
      { role = 'tool', content = 'result', created = os.time() },
      { role = nil, created = os.time() },
    },
  })
  lu.assertStrContains(html, '👤 user')
  lu.assertStrContains(html, '🤖 assistant')
  lu.assertStrContains(html, '🔧 tool')
  lu.assertStrContains(html, 'role-unknown')
end

function TestPreview:test_generate_html_reasoning_and_tools()
  local html = preview.generate_html({
    id = 's',
    messages = {
      {
        role = 'assistant',
        reasoning_content = 'deep thought',
        content = 'ans',
        tool_calls = {
          { ['function'] = { name = 'read_file', arguments = '{"filepath":"x"}' } },
          { ['function'] = { name = 'bad_tool', arguments = 'not json' } },
        },
        created = os.time(),
      },
    },
  })
  lu.assertStrContains(html, 'deep thought')
  lu.assertStrContains(html, 'read_file')
  lu.assertStrContains(html, 'not json')
end

function TestPreview:test_generate_html_tool_error_and_result()
  local html = preview.generate_html({
    id = 's',
    messages = {
      { role = 'tool', tool_call_state = { error = 'failed!' }, created = os.time() },
      { role = 'tool', tool_call_state = { name = 'git_add' }, content = 'ok', created = os.time() },
    },
  })
  lu.assertStrContains(html, 'Tool Error')
  lu.assertStrContains(html, 'failed!')
  lu.assertStrContains(html, 'Tool execution complete: git_add')
end

function TestPreview:test_generate_html_complete_and_error()
  local html = preview.generate_html({
    id = 's',
    messages = {
      {
        role = 'assistant',
        on_complete = true,
        usage = {
          total_tokens = 100,
          prompt_tokens = 60,
          completion_tokens = 40,
          prompt_tokens_details = { cached_tokens = 30 },
        },
        created = os.time(),
      },
      { role = 'assistant', error = 'boom', created = os.time() },
    },
  })
  lu.assertStrContains(html, 'Tokens: 100 (60↑/40↓)')
  lu.assertStrContains(html, 'Cached: 30 tokens (50%)')
  lu.assertStrContains(html, 'boom')
end

function TestPreview:test_markdown_code_blocks()
  local html = preview.generate_html({
    id = 's',
    messages = {
      { role = 'assistant', content = 'Look:\n```lua\nprint("hi")\n```\ndone', created = os.time() },
    },
  })
  lu.assertStrContains(html, '<pre><code class="language-lua">')
  lu.assertStrContains(html, 'print(&quot;hi&quot;)')
  lu.assertStrContains(html, 'done')
end

function TestPreview:test_inline_markdown()
  local html = preview.generate_html({
    id = 's',
    messages = {
      { role = 'assistant', content = '**bold** *ital* `code`', created = os.time() },
    },
  })
  lu.assertStrContains(html, '<strong>bold</strong>')
  lu.assertStrContains(html, '<em>ital</em>')
  lu.assertStrContains(html, '<code class="inline-code">code</code>')
end

function TestPreview:test_unterminated_code_block()
  local html = preview.generate_html({
    id = 's',
    messages = {
      { role = 'assistant', content = 'text\n```lua\ncode without end', created = os.time() },
    },
  })
  -- unterminated block is treated as plain text, not a code block
  lu.assertFalse(html:find('language%-lua', 1, false) ~= nil)
  lu.assertStrContains(html, 'code without end')
end

function TestPreview:test_code_block_no_language()
  local html = preview.generate_html({
    id = 's',
    messages = {
      { role = 'assistant', content = '```\nplain code\n```', created = os.time() },
    },
  })
  lu.assertStrContains(html, 'language-plaintext')
end

TestContextTruncate = {}

local function make_messages(n, pattern)
  local msgs = {}
  for i = 1, n do
    local role
    if pattern then
      role = pattern[((i - 1) % #pattern) + 1]
    else
      role = (i % 3 == 0) and 'assistant' or 'user'
    end
    table.insert(msgs, { role = role, content = 'm' .. i })
  end
  return msgs
end

function TestContextTruncate:test_no_truncation_below_threshold()
  local msgs = make_messages(10)
  local result, truncated = context.truncate_messages(msgs)
  lu.assertFalse(truncated)
  lu.assertEquals(result, msgs)
end

function TestContextTruncate:test_nil_messages()
  local result, truncated = context.truncate_messages(nil)
  lu.assertNil(result)
  lu.assertFalse(truncated)
end

function TestContextTruncate:test_truncation_basic()
  local msgs = {}
  table.insert(msgs, { role = 'system', content = 'sys' })
  for i = 1, 59 do
    table.insert(msgs, { role = 'user', content = 'm' .. i })
  end
  local result, truncated = context.truncate_messages(msgs)
  lu.assertTrue(truncated)
  lu.assertEquals(result[1].role, 'system')
  lu.assertEquals(result[2].role, 'system', 'context notice is a system message')
  lu.assertStrContains(result[2].content, 'Context Window Notice')
  -- 59 non-system msgs, keep_recent=10 -> start ~50
  lu.assertTrue(#result < #msgs)
end

function TestContextTruncate:test_truncation_respects_config()
  local msgs = make_messages(60)
  local result, truncated = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 3,
  })
  lu.assertTrue(truncated)
  -- 60 msgs, cutoff backtracks from idx 57 to nearest user (56),
  -- kept = 56..60 (5 msgs) + 1 context notice
  lu.assertEquals(#result, 6)
  lu.assertEquals(result[1].role, 'system', 'context notice first')
end

function TestContextTruncate:test_cutoff_before_first_user_no_truncation()
  -- All assistant messages: no user boundary found -> safety fallback
  local msgs = { { role = 'system', content = 'sys' } }
  for i = 1, 59 do
    table.insert(msgs, { role = 'assistant', content = 'm' .. i })
  end
  local result, truncated = context.truncate_messages(msgs)
  lu.assertFalse(truncated)
  lu.assertEquals(result, msgs)
end

function TestContextTruncate:test_cutoff_negative_no_truncation()
  local msgs = make_messages(60)
  local _, truncated = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 100,
  })
  lu.assertFalse(truncated)
end

function TestContextTruncate:test_orphaned_tool_result_removed()
  -- A user message separates the assistant tool_call from its result;
  -- truncation keeps from the user boundary, orphaning the tool result
  local msgs = { { role = 'system', content = 'sys' } }
  for i = 1, 39 do
    table.insert(msgs, { role = 'user', content = 'u' .. i })
  end
  table.insert(msgs, { role = 'assistant', tool_calls = { { id = 'tc1' } } }) -- idx 40 (truncated away)
  table.insert(msgs, { role = 'user', content = 'confirm?' }) -- idx 41 = start boundary
  table.insert(msgs, { role = 'tool', tool_call_id = 'tc1', content = 'orphan result' }) -- idx 42 (kept)
  for i = 1, 10 do
    table.insert(msgs, { role = 'user', content = 'recent' .. i }) -- idx 43-52
  end

  local result, truncated = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 10,
  })
  lu.assertTrue(truncated)
  local has_orphan = false
  for _, m in ipairs(result) do
    if m.role == 'tool' and m.tool_call_id == 'tc1' then
      has_orphan = true
    end
  end
  lu.assertFalse(has_orphan, 'orphaned tool result should be removed')
end

function TestContextTruncate:test_orphaned_tool_call_removed()
  -- assistant tool_call (no result, no text) lands inside the kept window
  local msgs = { { role = 'system', content = 'sys' } }
  for i = 1, 45 do
    table.insert(msgs, { role = 'user', content = 'u' .. i })
  end
  -- idx 46: assistant with tool_calls only (will be kept, then dropped)
  table.insert(msgs, { role = 'assistant', tool_calls = { { id = 'tc2' } } })
  for i = 1, 8 do
    table.insert(msgs, { role = 'user', content = 'recent' .. i }) -- idx 47-54
  end

  local result, truncated = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 10,
  })
  lu.assertTrue(truncated)
  for _, m in ipairs(result) do
    if m.role == 'assistant' and m.tool_calls then
      for _, tc in ipairs(m.tool_calls) do
        lu.assertNotEquals(tc.id, 'tc2', 'orphaned tool_call removed')
      end
    end
  end
end

function TestContextTruncate:test_tool_call_with_content_kept_without_calls()
  -- assistant with BOTH text and orphaned tool_calls: keep text, strip calls
  local msgs = { { role = 'system', content = 'sys' } }
  for i = 1, 45 do
    table.insert(msgs, { role = 'user', content = 'u' .. i })
  end
  table.insert(msgs, {
    role = 'assistant',
    content = 'text answer',
    tool_calls = { { id = 'tc3' } },
  }) -- idx 46, inside kept window
  for i = 1, 8 do
    table.insert(msgs, { role = 'user', content = 'recent' .. i }) -- idx 47-54
  end

  local result = context.truncate_messages(msgs, {
    trigger_threshold = 10,
    keep_recent = 10,
  })
  local kept_with_text = false
  for _, m in ipairs(result) do
    if m.role == 'assistant' and m.content == 'text answer' then
      kept_with_text = true
      lu.assertNil(m.tool_calls, 'tool_calls stripped when orphaned')
    end
  end
  lu.assertTrue(kept_with_text)
end

function TestContextTruncate:test_generate_context_notice()
  local notice = context._generate_context_notice(100, 40, 10, 60)
  lu.assertStrContains(notice, '100 total')
  lu.assertStrContains(notice, '10-60')
  lu.assertStrContains(notice, '100 messages in total history')
  lu.assertStrContains(notice, '40 messages')
end

function TestContextTruncate:test_get_stats()
  lu.assertEquals(context.get_stats(nil), { count = 0 })
  local stats = context.get_stats({
    { role = 'user' },
    { role = 'user' },
    { role = 'assistant' },
    { role = 'tool' },
    { role = 'system' },
    { role = 'unknown' },
  })
  lu.assertEquals(stats.count, 6)
  lu.assertEquals(stats.user_count, 2)
  lu.assertEquals(stats.assistant_count, 1)
  lu.assertEquals(stats.tool_count, 1)
  lu.assertEquals(stats.system_count, 1)
end

TestQueue = {}

local Q = {}

local function queue_stubs()
  package.loaded['chat.windows'] = {
    send_message = function(session, msg)
      Q.sent[#Q.sent + 1] = { session = session, msg = msg }
      return Q.send_result
    end,
  }
  package.loaded['chat.sessions'] = {
    is_in_progress = function()
      return Q.in_progress
    end,
  }
end

function TestQueue:setUp()
  Q = { sent = {}, send_result = nil, in_progress = false }
  queue_stubs()
  queue.stop()
end

function TestQueue:tearDown()
  queue.stop()
  package.loaded['chat.windows'] = real_windows
  package.loaded['chat.sessions'] = real_sessions
end

function TestQueue:test_push_and_process()
  -- A successful send makes the session busy (in_progress flips to true)
  package.loaded['chat.windows'].send_message = function(session, msg)
    Q.sent[#Q.sent + 1] = { session = session, msg = msg }
    Q.in_progress = true
    return nil
  end
  queue.push('q-sess', 'hello')
  wait_schedule()
  lu.assertEquals(#Q.sent, 1)
  lu.assertEquals(Q.sent[1].msg, 'hello')
  lu.assertFalse(queue.has_pending('q-sess'))
end

function TestQueue:test_push_when_busy_defers()
  Q.in_progress = true
  queue.push('busy-sess', 'later')
  wait_schedule(100)
  lu.assertEquals(#Q.sent, 0, 'message not sent while busy')
  lu.assertTrue(queue.has_pending('busy-sess'))
  -- becomes free
  Q.in_progress = false
  -- make the freed-up send SUCCEED (session becomes busy) so nothing
  -- is requeued and left behind in the module-level queue
  package.loaded['chat.windows'].send_message = function(session, msg)
    Q.sent[#Q.sent + 1] = { session = session, msg = msg }
    Q.in_progress = true
    return nil
  end
  queue._process_queue()
  lu.assertEquals(#Q.sent, 1)
end

function TestQueue:test_pop_empty()
  lu.assertNil(queue.pop('nope'))
  lu.assertFalse(not not queue.has_pending('nope'))
end

function TestQueue:test_skill_result_marks_handled()
  Q.send_result = true
  queue.push('skill-sess', '/model gpt-4')
  wait_schedule()
  lu.assertEquals(#Q.sent, 1)
  lu.assertFalse(queue.has_pending('skill-sess'))
end

function TestQueue:test_failed_send_requeues_then_drops()
  queue.push('fail-sess', 'msg')
  wait_schedule(50)
  -- First attempt (from push) failed -> requeued
  lu.assertEquals(#Q.sent, 1)
  lu.assertTrue(queue.has_pending('fail-sess'))
  -- Second attempt
  queue._process_queue()
  lu.assertEquals(#Q.sent, 2)
  lu.assertTrue(queue.has_pending('fail-sess'))
  -- Third attempt hits MAX_RETRIES -> dropped
  queue._process_queue()
  lu.assertEquals(#Q.sent, 3)
  lu.assertFalse(queue.has_pending('fail-sess'), 'message dropped after retries')
end

function TestQueue:test_successful_send_resets_retry()
  Q.in_progress = false
  local orig_send = package.loaded['chat.windows'].send_message
  package.loaded['chat.windows'].send_message = function(session, msg)
    Q.sent[#Q.sent + 1] = { session = session, msg = msg }
    Q.in_progress = true -- send succeeded, session now busy
    return nil
  end
  queue.push('ok-sess', 'msg')
  wait_schedule()
  lu.assertEquals(#Q.sent, 1)
  lu.assertFalse(queue.has_pending('ok-sess'))
  package.loaded['chat.windows'].send_message = orig_send
  queue.stop()
end

function TestQueue:test_process_queue_empty_stops_timer()
  queue._process_queue()
  -- No error, nothing sent
  lu.assertEquals(#Q.sent, 0)
end

function TestQueue:test_start_noop()
  queue.start()
  queue.stop()
end

TestSpinners = {}

function TestSpinners:setUp()
  self.titles = {}
  package.loaded['chat.windows'] = {
    set_result_win_title = function(t)
      self.titles[#self.titles + 1] = t
    end,
  }
end

function TestSpinners:tearDown()
  require('chat.spinners').stop()
  package.loaded['chat.windows'] = real_windows
end

function TestSpinners:test_start_stop()
  local spinners = require('chat.spinners')
  spinners.stop()
  spinners.start()
  lu.assertNotNil(spinners.id)
  lu.assertTrue(#self.titles >= 1)
  lu.assertStrContains(self.titles[1], 'chat.nvim')
  -- Wait for at least one frame rotation
  wait_schedule(200)
  spinners.stop()
  lu.assertNil(spinners.id)
  lu.assertStrContains(self.titles[#self.titles], 'chat.nvim')
end

function TestSpinners:test_start_idempotent()
  local spinners = require('chat.spinners')
  spinners.stop()
  spinners.start()
  local id = spinners.id
  spinners.start()
  lu.assertEquals(spinners.id, id, 'second start is a no-op')
  spinners.stop()
end

TestNudge = {}

function TestNudge:setUp()
  self.current = nil
  self.windows_calls = {}
  package.loaded['chat.windows'] = {
    on_message = function(sid, msg)
      self.windows_calls[#self.windows_calls + 1] = msg
    end,
    current_session = function()
      return self.current
    end,
    redraw_title = function() end,
    set_result_win_title = function() end,
  }
  self.request_calls = 0
  package.loaded['chat.protocol'] = {
    request = function(opt)
      self.request_calls = self.request_calls + 1
      self.last_request = opt
      return 42
    end,
  }
  local sessions = require('chat.sessions')
  self.sessions = sessions
  self.sessions_module = real_sessions
end

function TestNudge:tearDown()
  package.loaded['chat.windows'] = real_windows
  package.loaded['chat.sessions'] = real_sessions
  package.loaded['chat.protocol'] = real_protocol
  require('chat.spinners').stop()
end

function TestNudge:make_repo(dirty)
  local dir = vim.fn.tempname() .. '_nudge'
  vim.fn.mkdir(dir, 'p')
  vim.fn.system({ 'git', '-C', dir, 'init' })
  vim.fn.system({ 'git', '-C', dir, 'config', 'user.email', 't@t.com' })
  vim.fn.system({ 'git', '-C', dir, 'config', 'user.name', 'T' })
  if dirty then
    vim.fn.writefile({ 'dirty' }, dir .. '/f.txt')
  end
  return dir
end

function TestNudge:test_nudge_on_dirty_repo()
  if vim.fn.executable('git') ~= 1 then
    return
  end
  local dir = self:make_repo(true)
  local sid = real_sessions.new()
  real_sessions.change_cwd(sid, dir)
  self.current = sid

  local nudge = require('chat.sessions.nudge')
  nudge.nudge_if_dirty(sid)
  wait_schedule(100)

  local msgs = real_sessions.get_messages(sid)
  lu.assertTrue(#msgs >= 1, 'nudge message appended')
  lu.assertStrContains(msgs[1].content, '未提交')
  lu.assertEquals(self.request_calls, 1, 'new request triggered')
  lu.assertTrue(self.request_calls == 1)

  -- Second nudge in same turn is suppressed
  nudge.nudge_if_dirty(sid)
  lu.assertEquals(self.request_calls, 1, 'no double nudge')

  vim.fn.delete(dir, 'rf')
end

function TestNudge:test_no_nudge_on_clean_repo()
  if vim.fn.executable('git') ~= 1 then
    return
  end
  local dir = self:make_repo(false)
  local sid = real_sessions.new()
  real_sessions.change_cwd(sid, dir)

  require('chat.sessions.nudge').nudge_if_dirty(sid)
  wait_schedule(100)
  lu.assertEquals(self.request_calls, 0)
  lu.assertEquals(#real_sessions.get_messages(sid), 0)
  vim.fn.delete(dir, 'rf')
end

function TestNudge:test_no_nudge_on_non_git_dir()
  local dir = vim.fn.tempname() .. '_plain'
  vim.fn.mkdir(dir, 'p')
  local sid = real_sessions.new()
  real_sessions.change_cwd(sid, dir)
  require('chat.sessions.nudge').nudge_if_dirty(sid)
  wait_schedule(100)
  lu.assertEquals(self.request_calls, 0)
  vim.fn.delete(dir, 'rf')
end

function TestNudge:test_reset_allows_nudge_again()
  if vim.fn.executable('git') ~= 1 then
    return
  end
  local dir = self:make_repo(true)
  local sid = real_sessions.new()
  real_sessions.change_cwd(sid, dir)
  -- same-second sid may collide with an earlier test's session;
  -- clear any leaked nudge flag first
  local nudge = require('chat.sessions.nudge')
  nudge.reset(sid)
  -- nudge only fires for the session visible in the chat window
  self.current = sid

  local nudge = require('chat.sessions.nudge')
  nudge.nudge_if_dirty(sid)
  wait_schedule(100)
  lu.assertEquals(self.request_calls, 1)
  nudge.reset(sid)
  nudge.nudge_if_dirty(sid)
  wait_schedule(100)
  lu.assertEquals(self.request_calls, 2, 'nudge again after reset')
  vim.fn.delete(dir, 'rf')
end

function TestNudge:test_unknown_session_ignored()
  require('chat.sessions.nudge').nudge_if_dirty('missing-session')
  lu.assertEquals(self.request_calls, 0)
end


local lu = require('luaunit')

TestProtocol = {}

function TestProtocol:test_anthropic_convert_tool_result()
  local anthropic = require('chat.protocol.anthropic')

  -- Test tool result conversion
  local messages = {
    {
      role = 'user',
      content = 'Search for CURL_ERRORS',
    },
    {
      role = 'assistant',
      tool_calls = {
        {
          id = 'toolu_search_text:0',
          type = 'function',
          ['function'] = {
            name = 'search_text',
            arguments = '{"pattern": "CURL_ERRORS"}',
          },
        },
      },
    },
    {
      role = 'tool',
      tool_call_id = 'toolu_search_text:0',
      content = 'Found 9 matches in 3 files',
    },
  }

  local system_prompt, anthropic_messages = anthropic.convert_message(messages)

  -- Verify system prompt
  lu.assertIsNil(system_prompt)

  -- Verify message count
  lu.assertEquals(#anthropic_messages, 3)

  -- Verify first message (user)
  lu.assertEquals(anthropic_messages[1].role, 'user')
  lu.assertEquals(anthropic_messages[1].content[1].type, 'text')
  lu.assertEquals(anthropic_messages[1].content[1].text, 'Search for CURL_ERRORS')

  -- Verify second message (assistant with tool_use)
  lu.assertEquals(anthropic_messages[2].role, 'assistant')
  lu.assertEquals(#anthropic_messages[2].content, 1)
  lu.assertEquals(anthropic_messages[2].content[1].type, 'tool_use')
  lu.assertEquals(anthropic_messages[2].content[1].id, 'toolu_search_text:0')
  lu.assertEquals(anthropic_messages[2].content[1].name, 'search_text')
  lu.assertEquals(anthropic_messages[2].content[1].input, vim.json.decode('{"pattern": "CURL_ERRORS"}'))

  -- Verify third message (tool result)
  lu.assertEquals(anthropic_messages[3].role, 'user')
  lu.assertEquals(#anthropic_messages[3].content, 1)
  lu.assertEquals(anthropic_messages[3].content[1].type, 'tool_result')
  lu.assertEquals(anthropic_messages[3].content[1].tool_use_id, 'toolu_search_text:0')
  -- The content should be an array of content blocks
  lu.assertIsTable(anthropic_messages[3].content[1].content)
  lu.assertEquals(#anthropic_messages[3].content[1].content, 1)
  lu.assertEquals(anthropic_messages[3].content[1].content[1].type, 'text')
  lu.assertEquals(anthropic_messages[3].content[1].content[1].text, 'Found 9 matches in 3 files')
end

function TestProtocol:test_anthropic_convert_message_with_thinking()
  local anthropic = require('chat.protocol.anthropic')

  -- Test message with thinking/reasoning content
  local messages = {
    {
      role = 'user',
      content = 'What is 2+2?',
    },
    {
      role = 'assistant',
      reasoning_content = 'Let me think about this...',
      content = 'The answer is 4.',
    },
  }

  local system_prompt, anthropic_messages = anthropic.convert_message(messages)

  lu.assertEquals(#anthropic_messages, 2)

  -- Verify assistant message with thinking
  lu.assertEquals(anthropic_messages[2].role, 'assistant')
  lu.assertEquals(#anthropic_messages[2].content, 2)
  lu.assertEquals(anthropic_messages[2].content[1].type, 'thinking')
  lu.assertEquals(anthropic_messages[2].content[1].thinking, 'Let me think about this...')
  lu.assertEquals(anthropic_messages[2].content[2].type, 'text')
  lu.assertEquals(anthropic_messages[2].content[2].text, 'The answer is 4.')
end

function TestProtocol:test_anthropic_convert_system_prompt()
  local anthropic = require('chat.protocol.anthropic')

  local messages = {
    {
      role = 'system',
      content = 'You are a helpful assistant.',
    },
    {
      role = 'user',
      content = 'Hello!',
    },
  }

  local system_prompt, anthropic_messages = anthropic.convert_message(messages)

  lu.assertEquals(system_prompt, 'You are a helpful assistant.')
  lu.assertEquals(#anthropic_messages, 1)
  lu.assertEquals(anthropic_messages[1].role, 'user')
end

function TestProtocol:test_anthropic_merges_multiple_system_messages()
  -- get_request_messages can emit two system entries (session prompt + user
  -- profile); convert_message must merge them, not keep only the last one.
  local anthropic = require('chat.protocol.anthropic')

  local messages = {
    { role = 'system', content = 'Session prompt.' },
    { role = 'system', content = 'User profile.' },
    { role = 'user', content = 'Hi' },
  }

  local system_prompt, anthropic_messages = anthropic.convert_message(messages)

  lu.assertStrContains(system_prompt, 'Session prompt.')
  lu.assertStrContains(system_prompt, 'User profile.')
  lu.assertEquals(#anthropic_messages, 1)
end

function TestProtocol:test_anthropic_mid_conversation_system_becomes_user_message()
  -- context.truncate_messages appends the context window notice as a
  -- trailing system message. Merging it into the top-level system prompt
  -- would move per-turn changing content to the request head and defeat
  -- prompt caching; it must become a trailing user message instead.
  local anthropic = require('chat.protocol.anthropic')

  local messages = {
    { role = 'system', content = 'Session prompt.' },
    { role = 'user', content = 'Hi' },
    { role = 'assistant', content = 'Hello!' },
    { role = 'system', content = '[Context Window Notice] truncated history' },
  }

  local system_prompt, anthropic_messages = anthropic.convert_message(messages)

  -- Only leading system messages feed the top-level system prompt
  lu.assertEquals(system_prompt, 'Session prompt.')
  lu.assertEquals(#anthropic_messages, 3)
  lu.assertEquals(anthropic_messages[3].role, 'user')
  lu.assertEquals(anthropic_messages[3].content[1].type, 'text')
  lu.assertStrContains(
    anthropic_messages[3].content[1].text,
    '[Context Window Notice]'
  )
end

function TestProtocol:test_anthropic_system_prompt_stable_across_truncation()
  -- End-to-end: once context truncation kicks in and appends the notice,
  -- the top-level system prompt must stay byte-identical so Anthropic's
  -- cached system + tools blocks remain valid across turns.
  local anthropic = require('chat.protocol.anthropic')
  local context = require('chat.context')

  local msgs = { { role = 'system', content = 'Session prompt.' } }
  for i = 1, 59 do
    table.insert(msgs, { role = 'user', content = 'm' .. i })
  end

  local sys_before = anthropic.convert_message(msgs)

  -- Conversation grows past the truncation threshold
  table.insert(msgs, { role = 'assistant', content = 'ok' })
  table.insert(msgs, { role = 'user', content = 'more' })
  local truncated, did_truncate = context.truncate_messages(msgs)
  lu.assertTrue(did_truncate)
  lu.assertEquals(truncated[#truncated].role, 'system')
  lu.assertStrContains(truncated[#truncated].content, 'Context Window Notice')

  local sys_after, after = anthropic.convert_message(truncated)

  lu.assertEquals(sys_before, 'Session prompt.')
  lu.assertEquals(sys_after, sys_before, 'system prompt untouched by notice')
  -- The notice rides at the tail as a user text message
  lu.assertEquals(after[#after].role, 'user')
  lu.assertStrContains(after[#after].content[1].text, 'Context Window Notice')
end

function TestProtocol:test_anthropic_convert_reasoning_only_assistant()
  -- A truncated reasoning-only turn (no content, no tool_calls) still needs
  -- a non-empty content array for Anthropic's API.
  local anthropic = require('chat.protocol.anthropic')

  local messages = {
    { role = 'user', content = 'Think hard' },
    { role = 'assistant', reasoning_content = 'halfway through thinking' },
  }

  local _, anthropic_messages = anthropic.convert_message(messages)

  lu.assertEquals(#anthropic_messages, 2)
  lu.assertEquals(#anthropic_messages[2].content, 1)
  lu.assertEquals(anthropic_messages[2].content[1].type, 'thinking')
end

return TestProtocol


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
  lu.assertEquals(anthropic_messages[2].content[1].input, '{"pattern": "CURL_ERRORS"}')

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

return TestProtocol

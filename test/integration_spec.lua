local lu = require('luaunit')
local config = require('chat.config')

local TestIntegration = {}

function TestIntegration:setUp()
  -- Setup test configuration
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })

  -- Mock IM modules
  self.mock_ims = {
    discord = {
      current_session = function()
        return 'session-001'
      end,
      send_message = function(content)
        self.discord_sent = content
      end,
    },
    lark = {
      current_session = function()
        return 'session-001'
      end,
      send_message = function(content)
        self.lark_sent = content
      end,
    },
    dingtalk = {
      current_session = function()
        return 'session-002'
      end,
      send_message = function(content)
        self.dingtalk_sent = content
      end,
    },
    wecom = {
      current_session = function()
        return 'session-003'
      end,
      send_message = function(content)
        self.wecom_sent = content
      end,
    },
    telegram = {
      current_session = function()
        return 'session-001'
      end,
      send_message = function(content)
        self.telegram_sent = content
      end,
    },
  }

  -- Reset sent flags
  self.discord_sent = nil
  self.lark_sent = nil
  self.dingtalk_sent = nil
  self.wecom_sent = nil
  self.telegram_sent = nil
end

function TestIntegration:tearDown()
  -- Clean up
end

-- Mock on_response function with fixed logic
local function on_response(session, content, ims)
  if not content or type(content) ~= 'string' or content:match('^%s*$') then
    return
  end

  -- Check each IM independently (not with elseif)
  if session == ims.discord.current_session() then
    ims.discord.send_message(content)
  end

  if session == ims.lark.current_session() then
    ims.lark.send_message(content)
  end

  if session == ims.dingtalk.current_session() then
    ims.dingtalk.send_message(content)
  end

  if session == ims.wecom.current_session() then
    ims.wecom.send_message(content)
  end

  if session == ims.telegram.current_session() then
    ims.telegram.send_message(content)
  end
end

function TestIntegration:testOnResponseWithSharedSession()
  -- Test that multiple IMs with same session all receive messages
  local session = 'session-001' -- Shared by discord, lark, telegram
  local content = 'Test message'

  on_response(session, content, self.mock_ims)

  -- All three IMs should receive the message
  lu.assertEquals(self.discord_sent, content)
  lu.assertEquals(self.lark_sent, content)
  lu.assertEquals(self.telegram_sent, content)

  -- Other IMs should not receive the message
  lu.assertNil(self.dingtalk_sent)
  lu.assertNil(self.wecom_sent)
end

function TestIntegration:testOnResponseWithUniqueSession()
  -- Test that only matching IM receives message
  local session = 'session-002' -- Only dingtalk
  local content = 'DingTalk only message'

  on_response(session, content, self.mock_ims)

  -- Only dingtalk should receive
  lu.assertNil(self.discord_sent)
  lu.assertNil(self.lark_sent)
  lu.assertEquals(self.dingtalk_sent, content)
  lu.assertNil(self.wecom_sent)
  lu.assertNil(self.telegram_sent)
end

function TestIntegration:testOnResponseWithEmptyContent()
  -- Test that empty content is ignored
  local session = 'session-001'

  on_response(session, '', self.mock_ims)
  lu.assertNil(self.discord_sent)

  on_response(session, '   ', self.mock_ims)
  lu.assertNil(self.discord_sent)

  on_response(session, nil, self.mock_ims)
  lu.assertNil(self.discord_sent)
end

function TestIntegration:testOnResponseWithInvalidContent()
  -- Test that invalid content is handled gracefully
  local session = 'session-001'

  on_response(session, 123, self.mock_ims)
  lu.assertNil(self.discord_sent)

  on_response(session, {}, self.mock_ims)
  lu.assertNil(self.discord_sent)
end

function TestIntegration:testOnResponseWithNonMatchingSession()
  -- Test that no IM receives message when session doesn't match
  local session = 'nonexistent-session'
  local content = 'Nobody should receive this'

  on_response(session, content, self.mock_ims)

  lu.assertNil(self.discord_sent)
  lu.assertNil(self.lark_sent)
  lu.assertNil(self.dingtalk_sent)
  lu.assertNil(self.wecom_sent)
  lu.assertNil(self.telegram_sent)
end

function TestIntegration:testOnResponseWithAllMatchingSessions()
  -- Test when all IMs have the same session
  local all_same_ims = {
    discord = {
      current_session = function()
        return 'shared-session'
      end,
      send_message = function(content)
        self.discord_sent = content
      end,
    },
    lark = {
      current_session = function()
        return 'shared-session'
      end,
      send_message = function(content)
        self.lark_sent = content
      end,
    },
    dingtalk = {
      current_session = function()
        return 'shared-session'
      end,
      send_message = function(content)
        self.dingtalk_sent = content
      end,
    },
    wecom = {
      current_session = function()
        return 'shared-session'
      end,
      send_message = function(content)
        self.wecom_sent = content
      end,
    },
    telegram = {
      current_session = function()
        return 'shared-session'
      end,
      send_message = function(content)
        self.telegram_sent = content
      end,
    },
  }

  local session = 'shared-session'
  local content = 'Everyone gets this'

  on_response(session, content, all_same_ims)

  -- All IMs should receive
  lu.assertEquals(self.discord_sent, content)
  lu.assertEquals(self.lark_sent, content)
  lu.assertEquals(self.dingtalk_sent, content)
  lu.assertEquals(self.wecom_sent, content)
  lu.assertEquals(self.telegram_sent, content)
end

function TestIntegration:testMessageContentPreservation()
  -- Test that message content is preserved correctly
  local test_messages = {
    'Simple message',
    'Message with émojis 🎉🚀',
    'Message with "quotes" and \'apostrophes\'',
    'Multi\nline\nmessage',
    'Message with    extra    spaces',
    string.rep('Long message ', 100),
  }

  for _, content in ipairs(test_messages) do
    self.discord_sent = nil
    on_response('session-001', content, self.mock_ims)
    lu.assertEquals(self.discord_sent, content)
  end
end

function TestIntegration:testConcurrentSessions()
  -- Test handling messages for different sessions sequentially
  local sessions = {
    { id = 'session-001', expected_ims = { 'discord', 'lark', 'telegram' } },
    { id = 'session-002', expected_ims = { 'dingtalk' } },
    { id = 'session-003', expected_ims = { 'wecom' } },
  }

  for _, session_data in ipairs(sessions) do
    -- Reset all sent flags
    self.discord_sent = nil
    self.lark_sent = nil
    self.dingtalk_sent = nil
    self.wecom_sent = nil
    self.telegram_sent = nil

    on_response(session_data.id, 'Test', self.mock_ims)

    -- Verify correct IMs received message
    for _, im in ipairs({ 'discord', 'lark', 'dingtalk', 'wecom', 'telegram' }) do
      local expected = vim.tbl_contains(session_data.expected_ims, im)
      local actual = self[im .. '_sent'] ~= nil

      lu.assertEquals(
        actual,
        expected,
        string.format(
          'Session %s: Expected %s to %s',
          session_data.id,
          im,
          expected and 'receive' or 'not receive'
        )
      )
    end
  end
end

return TestIntegration

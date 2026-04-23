-- test/config_spec.lua
local lu = require('luaunit')
local config = require('chat.config')

TestConfig = {}

function TestConfig:setUp()
  -- Reset config to default values before each test
  -- We need to manually reset because config.setup({}) doesn't reset previous values
  config.config.provider = 'deepseek'
  config.config.model = 'deepseek-chat'
  config.config.width = 0.8
  config.config.height = 0.8
  config.config.border = 'rounded'
  config.config.auto_scroll = true
end

function TestConfig:testDefaultConfig()
  lu.assertEquals(config.config.width, 0.8)
  lu.assertEquals(config.config.height, 0.8)
  lu.assertEquals(config.config.provider, 'deepseek')
  lu.assertEquals(config.config.model, 'deepseek-chat')
  lu.assertEquals(config.config.border, 'rounded')
  lu.assertEquals(config.config.auto_scroll, true)
end

function TestConfig:testSetupWithCustomConfig()
  config.setup({
    width = 0.9,
    height = 0.9,
    provider = 'openai',
    model = 'gpt-4',
  })

  lu.assertEquals(config.config.width, 0.9)
  lu.assertEquals(config.config.height, 0.9)
  lu.assertEquals(config.config.provider, 'openai')
  lu.assertEquals(config.config.model, 'gpt-4')
end

function TestConfig:testSetupWithAPIKeys()
  config.setup({
    api_key = {
      deepseek = 'sk-test-deepseek',
      openai = 'sk-test-openai',
    },
  })

  lu.assertEquals(config.config.api_key.deepseek, 'sk-test-deepseek')
  lu.assertEquals(config.config.api_key.openai, 'sk-test-openai')
end

function TestConfig:testSystemPromptString()
  config.setup({
    system_prompt = 'You are a helpful assistant.',
  })

  lu.assertEquals(config.config.system_prompt, 'You are a helpful assistant.')
end

function TestConfig:testSystemPromptFunction()
  config.setup({
    system_prompt = function()
      return 'Dynamic prompt'
    end,
  })

  lu.assertEquals(type(config.config.system_prompt), 'function')
  lu.assertEquals(config.config.system_prompt(), 'Dynamic prompt')
end

function TestConfig:testInvalidSystemPrompt()
  config.setup({
    system_prompt = 123, -- Invalid type
  })

  -- Should not crash, but should log error
  -- The actual value depends on implementation
  lu.assertNotEquals(config.config.system_prompt, 123)
end

function TestConfig:testMemoryConfig()
  config.setup({
    memory = {
      enable = true,
      long_term = {
        max_memories = 1000,
      },
    },
  })

  lu.assertEquals(config.config.memory.enable, true)
  lu.assertEquals(config.config.memory.long_term.max_memories, 1000)
end

function TestConfig:testHTTPConfig()
  config.setup({
    http = {
      host = '127.0.0.1',
      port = 8080,
      api_key = 'test-key',
    },
  })

  lu.assertEquals(config.config.http.host, '127.0.0.1')
  lu.assertEquals(config.config.http.port, 8080)
  lu.assertEquals(config.config.http.api_key, 'test-key')
end

function TestConfig:testAllowedPath()
  -- Test single path
  config.setup({
    allowed_path = '/home/user/project',
  })
  lu.assertEquals(config.config.allowed_path, '/home/user/project')

  -- Test multiple paths
  config.setup({
    allowed_path = {
      '/home/user/project1',
      '/home/user/project2',
    },
  })
  lu.assertEquals(type(config.config.allowed_path), 'table')
  lu.assertEquals(#config.config.allowed_path, 2)
end

return TestConfig

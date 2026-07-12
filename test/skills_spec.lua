-- test/skills_spec.lua
local lu = require('luaunit')
local skills = require('chat.skills')
local config = require('chat.config')

TestSkills = {}

function TestSkills:setUp()
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })
  -- Reset registry: unregister all, then re-init builtins
  for _, s in ipairs(skills.list()) do
    skills.unregister(s.name)
  end
  skills.init()
end

function TestSkills:testRegisterBasic()
  local ok = skills.register({
    name = 'test1',
    description = 'Test skill',
    handler = function() end,
  })
  lu.assertTrue(ok)
  lu.assertNotNil(skills.get('test1'))
  lu.assertEquals(skills.get('test1').description, 'Test skill')
end

function TestSkills:testRegisterInvalid()
  -- Not a table
  lu.assertFalse(skills.register(nil))
  lu.assertFalse(skills.register('string'))

  -- Missing name
  lu.assertFalse(skills.register({ handler = function() end }))

  -- Empty name
  lu.assertFalse(skills.register({ name = '', handler = function() end }))

  -- Missing handler
  lu.assertFalse(skills.register({ name = 'nohandler' }))

  -- Handler not a function
  lu.assertFalse(skills.register({ name = 'badhandler', handler = 'not_fn' }))
end

function TestSkills:testUnregister()
  skills.register({
    name = 'temp',
    handler = function() end,
  })
  lu.assertNotNil(skills.get('temp'))

  skills.unregister('temp')
  lu.assertNil(skills.get('temp'))
end

function TestSkills:testList()
  local all = skills.list()
  -- Should have at least the built-in skills
  lu.assertTrue(#all >= 10)

  -- Verify sorted
  for i = 2, #all do
    lu.assertTrue(all[i - 1].name <= all[i].name)
  end
end

function TestSkills:testListContainsBuiltins()
  local names = {}
  for _, s in ipairs(skills.list()) do
    names[s.name] = true
  end
  lu.assertTrue(names['clear'])
  lu.assertTrue(names['new'])
  lu.assertTrue(names['delete'])
  lu.assertTrue(names['model'])
  lu.assertTrue(names['provider'])
  lu.assertTrue(names['cwd'])
  lu.assertTrue(names['pin'])
  lu.assertTrue(names['title'])
  lu.assertTrue(names['retry'])
  lu.assertTrue(names['help'])
end

function TestSkills:testParseSimple()
  local name, args = skills.parse('/clear')
  lu.assertEquals(name, 'clear')
  lu.assertEquals(args, '')
end

function TestSkills:testParseWithArgs()
  local name, args = skills.parse('/model gpt-4o')
  lu.assertEquals(name, 'model')
  lu.assertEquals(args, 'gpt-4o')
end

function TestSkills:testParseWithMultipleArgs()
  local name, args = skills.parse('/title My Cool Title')
  lu.assertEquals(name, 'title')
  lu.assertEquals(args, 'My Cool Title')
end

function TestSkills:testParseWithExtraSpaces()
  local name, args = skills.parse('/cwd   /tmp/test  ')
  lu.assertEquals(name, 'cwd')
  lu.assertEquals(args, '/tmp/test')
end

function TestSkills:testParseNotASkill()
  local name, args = skills.parse('hello world')
  lu.assertNil(name)
  lu.assertEquals(args, '')
end

function TestSkills:testParseNil()
  local name, args = skills.parse(nil)
  lu.assertNil(name)
end

function TestSkills:testParseEmptyString()
  local name, args = skills.parse('')
  lu.assertNil(name)
end

function TestSkills:testParseJustSlash()
  local name, args = skills.parse('/')
  lu.assertEquals(name, '')
  lu.assertEquals(args, '')
end

function TestSkills:testDispatchKnownSkill()
  local called = false
  local received_args = nil
  local received_session = nil

  skills.register({
    name = 'testdispatch',
    handler = function(args, ctx)
      called = true
      received_args = args
      received_session = ctx.session
    end,
  })

  local ok = skills.dispatch('/testdispatch hello', 'my-session')
  lu.assertTrue(ok)
  lu.assertTrue(called)
  lu.assertEquals(received_args, 'hello')
  lu.assertEquals(received_session, 'my-session')
end

function TestSkills:testDispatchNoArgs()
  local called = false
  skills.register({
    name = 'noargs',
    handler = function(args, ctx)
      called = true
      lu.assertEquals(args, '')
    end,
  })

  local ok = skills.dispatch('/noargs', 'session-1')
  lu.assertTrue(ok)
  lu.assertTrue(called)
end

function TestSkills:testDispatchUnknownSkill()
  local ok = skills.dispatch('/nonexistent', 'session-1')
  lu.assertFalse(ok)
end

function TestSkills:testDispatchNotASkill()
  local ok = skills.dispatch('hello world', 'session-1')
  lu.assertFalse(ok)
end

function TestSkills:testDispatchHandlerError()
  skills.register({
    name = 'errorskill',
    handler = function(args, ctx)
      error('intentional error')
    end,
  })

  -- Should not throw, should return true (skill was found)
  local ok = skills.dispatch('/errorskill', 'session-1')
  lu.assertTrue(ok)
end

function TestSkills:testBuiltinClear()
  lu.assertNotNil(skills.get('clear'))
  lu.assertEquals(skills.get('clear').builtin, true)
end

function TestSkills:testBuiltinHelp()
  lu.assertNotNil(skills.get('help'))
  lu.assertEquals(skills.get('help').builtin, true)
end

function TestSkills:testUserSkillOverridesBuiltin()
  -- Register a user skill with same name as builtin
  local called = false
  skills.register({
    name = 'clear',
    description = 'Custom clear',
    handler = function()
      called = true
    end,
  })

  -- Dispatch should call the user skill, not the builtin
  skills.dispatch('/clear', 'session-1')
  lu.assertTrue(called)
end

function TestSkills:testInitIdempotent()
  -- Call init again, should not duplicate
  skills.init()
  local count = 0
  for _, s in ipairs(skills.list()) do
    if s.name == 'help' then
      count = count + 1
    end
  end
  lu.assertEquals(count, 1)
end

function TestSkills:testInitAfterUnregister()
  -- Unregister all
  for _, s in ipairs(skills.list()) do
    skills.unregister(s.name)
  end
  lu.assertEquals(#skills.list(), 0)

  -- Re-init
  skills.init()
  lu.assertTrue(#skills.list() >= 10)
end

function TestSkills:testRegisterWithDefaultDescription()
  skills.register({
    name = 'nodesc',
    handler = function() end,
  })
  lu.assertEquals(skills.get('nodesc').description, '')
end

return TestSkills


-- Coverage for lua/chat/log.lua
-- Tests exercise the logger.nvim-backed paths (derived logger, view_all,
-- set_level) by stubbing the optional `logger` / `logger.base` / `notify`
-- modules in package.loaded. The real chat.log module state is preserved
-- across tests: a fresh copy is loaded with the stubs in place and the
-- original cached module is restored in tearDown so other specs that hold
-- a reference to chat.log keep the pristine behaviour.

local lu = require('luaunit')

TestLog = {}

function TestLog:setUp()
  self.orig_chat_log = package.loaded['chat.log']
  self.orig_logger = package.loaded['logger']
  self.orig_logger_base = package.loaded['logger.base']
  self.orig_notify = package.loaded['notify']
  package.loaded['chat.log'] = nil
end

function TestLog:tearDown()
  package.loaded['logger'] = self.orig_logger
  package.loaded['logger.base'] = self.orig_logger_base
  package.loaded['notify'] = self.orig_notify
  package.loaded['chat.log'] = self.orig_chat_log
  package.preload['logger'] = nil
  package.preload['logger.base'] = nil
  package.preload['notify'] = nil
end

function TestLog:test_derived_logger_receives_all_levels()
  local calls = {}
  local fake = {}
  for _, level in ipairs({ 'info', 'warn', 'error', 'debug' }) do
    fake[level] = function(msg)
      table.insert(calls, level .. ':' .. tostring(msg))
    end
  end
  fake.set_level = function(l)
    table.insert(calls, 'set_level:' .. tostring(l))
  end
  package.loaded['logger'] = {
    derive = function(name)
      lu.assertEquals('chat.nvim', name)
      return fake
    end,
  }
  local M = require('chat.log')
  M.info('hello')
  M.warn('w')
  M.error('e')
  M.debug('d')
  M.set_level(2)
  lu.assertEquals({
    'info:hello',
    'warn:w',
    'error:e',
    'debug:d',
    'set_level:2',
  }, calls)
end

function TestLog:test_derive_failure_disables_logging()
  package.loaded['logger'] = {
    derive = function()
      error('boom')
    end,
  }
  local M = require('chat.log')
  -- First call hits the failing derive and flips the internal
  -- logger_failed flag; later calls return early without raising.
  lu.assertNil(M.info('ignored'))
  lu.assertNil(M.warn('also ignored'))
  M.set_level(1) -- log is still nil: no-op, must not raise
end

function TestLog:test_without_logger_module_calls_are_swallowed()
  -- No `logger` module in the test runtime: require fails, the module
  -- marks itself as failed and all logging calls become silent no-ops.
  local M = require('chat.log')
  M.set_level(3) -- before any call: log is nil, no-op
  lu.assertNil(M.info('a'))
  lu.assertNil(M.error('b'))
  M.set_level(4) -- after failure: still nil, no-op
  lu.assertNil(M.view_all())
end

function TestLog:test_view_all_returns_log_string()
  package.loaded['logger.base'] = {
    view_all = function()
      return '[ 12:00:00:000 ] [ INFO ] [ chat.nvim ] hello'
    end,
  }
  local M = require('chat.log')
  lu.assertEquals('[ 12:00:00:000 ] [ INFO ] [ chat.nvim ] hello', M.view_all())
end

function TestLog:test_view_all_non_string_result_returns_nil()
  package.loaded['logger.base'] = {
    view_all = function()
      return { 'not', 'a', 'string' }
    end,
  }
  local M = require('chat.log')
  lu.assertNil(M.view_all())
end

function TestLog:test_view_all_view_raises_returns_nil()
  package.loaded['logger.base'] = {
    view_all = function()
      error('view failed')
    end,
  }
  local M = require('chat.log')
  lu.assertNil(M.view_all())
end

function TestLog:test_notify_uses_notify_module_when_available()
  local calls = {}
  package.loaded['notify'] = {
    notify = function(msg, color)
      table.insert(calls, { msg, color })
    end,
  }
  local M = require('chat.log')
  M.notify('hi', 'WarningMsg')
  M.notify({ 'multi', 'line' })
  lu.assertEquals(2, #calls)
  lu.assertEquals('hi', calls[1][1])
  lu.assertEquals('WarningMsg', calls[1][2])
end

function TestLog:test_notify_table_message_passes_through()
  local seen = {}
  package.loaded['notify'] = {
    notify = function(msg, color)
      seen.msg = msg
      seen.color = color
    end,
  }
  local M = require('chat.log')
  M.notify({ 'line one', 'line two' }, 'ErrorMsg')
  lu.assertEquals({ 'line one', 'line two' }, seen.msg)
  lu.assertEquals('ErrorMsg', seen.color)
end

return TestLog


-- Coverage for the keyword extraction, guidance message and rendering
-- branches of chat/tools/recall_memory.lua:
--   * query derived from the last user message keywords
--   * "no memories found" guidance incl. memory_type hint
--   * keyword fallback re-query when the first search misses
--   * format_time buckets (just now / min / hours / days / date)
--   * cwd folder suffix and working-memory metadata badges
--   * memory_type filtering of results

local lu = require('luaunit')

local tools = require('chat.tools')
local memory = require('chat.memory')
local storage = require('chat.sessions.storage')
local config = require('chat.config')

TestRecallMemoryExtra = {}

local SID = 'recall-extra-session'

function TestRecallMemoryExtra:setUp()
  self.orig = {}

  storage.sessions[SID] = {
    id = SID,
    messages = {},
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  }

  self.memory_enable_orig = config.config.memory
  config.config.memory = { enable = true }

  table.insert(self.orig, {
    module = memory,
    name = 'retrieve_memories',
    fn = memory.retrieve_memories,
  })
  self.retrieve_calls = {}
  self.memories_result = {}
  memory.retrieve_memories = function(query, session, limit)
    table.insert(self.retrieve_calls, {
      query = query,
      session = session,
      limit = limit,
    })
    return self.memories_result
  end
end

function TestRecallMemoryExtra:tearDown()
  for _, entry in ipairs(self.orig) do
    entry.module[entry.name] = entry.fn
  end
  config.config.memory = self.memory_enable_orig
  storage.sessions[SID] = nil
end

local function add_user_message(text)
  table.insert(storage.sessions[SID].messages, {
    role = 'user',
    content = text,
    created = os.time(),
  })
end

function TestRecallMemoryExtra:testQueryDerivedFromLastUserMessageKeywords()
  add_user_message('please help deploy the server config')
  self.memories_result = {
    {
      content = '[long_term][ops] server deployment notes',
      timestamp = os.time(),
      metadata = {},
    },
  }

  local result = tools.call('recall_memory', {}, { session = SID })

  lu.assertEquals(1, #self.retrieve_calls)
  local query = self.retrieve_calls[1].query
  -- two keywords are extracted from the last user message
  lu.assertEquals(2, #vim.split(query, ' '), 'expected exactly two keywords')
  -- stop words (the) are dropped, real keywords are kept
  lu.assertNil(query:find('%f[%a]the%f[%A]'), 'stop word leaked into query')
  lu.assertStrContains(result.content, 'server deployment notes')
end

function TestRecallMemoryExtra:testNoMemoriesFoundGuidance()
  self.memories_result = {}
  local result = tools.call('recall_memory', { query = 'nothing' }, { session = SID })
  lu.assertStrContains(result.content, 'No memories found related to "nothing"')
  lu.assertStrContains(result.content, '@extract_memory')
  lu.assertStrContains(result.content, '@recall_memory query="different keywords"')
end

function TestRecallMemoryExtra:testNoMemoriesFoundWithTypeHint()
  -- first retrieve returns nothing, keyword fallback also misses
  self.memories_result = {}
  local result = tools.call('recall_memory', {
    query = 'nonexistent',
    memory_type = 'daily',
  }, { session = SID })
  lu.assertStrContains(result.content, '(type: daily)')
end

function TestRecallMemoryExtra:testKeywordFallbackRequeries()
  -- first query (with the raw query) misses, the keyword re-query matches
  self.memories_result = {}
  local called = 0
  memory.retrieve_memories = function(query)
    called = called + 1
    if called == 1 then
      return {}
    end
    -- keyword fallback re-query finds a result
    return {
      {
        content = '[long_term][topic] fallback match',
        timestamp = os.time(),
        metadata = {},
      },
    }
  end

  local result = tools.call('recall_memory', { query = 'alpha beta' }, { session = SID })
  lu.assertEquals(2, called)
  lu.assertStrContains(result.content, 'fallback match')
end

function TestRecallMemoryExtra:testFormatTimeBuckets()
  local now = os.time()
  self.memories_result = {
    {
      content = '[long_term][a] just now entry',
      timestamp = now - 10,
      metadata = {},
    },
    {
      content = '[long_term][b] minutes ago entry',
      timestamp = now - 300,
      metadata = {},
    },
    {
      content = '[long_term][c] hours ago entry',
      timestamp = now - 7200,
      metadata = {},
    },
    {
      content = '[long_term][d] days ago entry',
      timestamp = now - 3 * 86400,
      metadata = {},
    },
    {
      content = '[long_term][e] dated entry',
      timestamp = now - 30 * 86400,
      metadata = {},
    },
  }

  local result = tools.call('recall_memory', { query = 'x' }, { session = SID })
  lu.assertStrContains(result.content, 'just now')
  lu.assertStrContains(result.content, 'min ago')
  lu.assertStrContains(result.content, 'hours ago')
  lu.assertStrContains(result.content, 'days ago')
  lu.assertStrContains(result.content, '🕒 ' .. os.date('%m-%d', now - 30 * 86400))
end

function TestRecallMemoryExtra:testFolderSuffixAndWorkingBadges()
  local now = os.time()
  self.memories_result = {
    {
      content = '[working][task] active task context',
      timestamp = now,
      metadata = {
        cwd = '/home/user/projects/chat-nvim',
        type = 'decision',
        importance = 'high',
      },
    },
  }

  local result = tools.call('recall_memory', { query = 'task' }, { session = SID })
  lu.assertStrContains(result.content, '📁 chat-nvim')
  lu.assertStrContains(result.content, '🏷️ decision')
  lu.assertStrContains(result.content, '⚠️ high')
end

function TestRecallMemoryExtra:testMemoryTypeFiltersResults()
  self.memories_result = {
    {
      content = '[daily][note] daily note',
      timestamp = os.time(),
      metadata = {},
    },
    {
      content = '[long_term][fact] long term fact',
      timestamp = os.time(),
      metadata = {},
    },
  }

  local result = tools.call('recall_memory', {
    query = 'anything',
    memory_type = 'daily',
  }, { session = SID })

  lu.assertStrContains(result.content, 'daily note')
  lu.assertStrContains(result.content, '📅 Daily: 1')
  -- long_term entries are filtered out
  lu.assertNil(result.content:find('long term fact', 1, true))
end

return TestRecallMemoryExtra


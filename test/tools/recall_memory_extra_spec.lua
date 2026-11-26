-- Coverage for the keyword extraction, guidance message and rendering
-- branches of chat/tools/recall_memory.lua:
--   * query derived from the last user message keywords
--   * "no memories found" guidance incl. memory_type hint
--   * keyword fallback re-query when the first search misses
--   * format_time buckets (just now / min / hours / days / date)
--   * cwd folder suffix and working-memory metadata badges
--   * memory_type filter forwarded to retrieve_memories (source-level)

local lu = require('luaunit')

local tools = require('chat.tools')
local memory = require('chat.memory')
local storage = require('chat.sessions.storage')
local config = require('chat.config')

TestRecallMemoryExtra = {}

local SID = 'recall-extra-session'

-- Mirror of the real memory_type tag stored in the memory content prefix:
-- "[<memory_type>][<category>] content"
local function type_of(entry)
  return entry.content:match('^%[(%w+)%]')
end

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
  self.retrieve_override = nil

  -- The real retrieve_memories filters by opts.memory_type at the source, so
  -- the stub must do the same: a stub that ignores opts would "pass" only
  -- because recall_memory used to filter results afterwards.
  memory.retrieve_memories = function(query, session, limit, opts)
    table.insert(self.retrieve_calls, {
      query = query,
      session = session,
      limit = limit,
      memory_type = opts and opts.memory_type or nil,
    })

    local result = self.memories_result
    local memory_type = opts and opts.memory_type
    if memory_type then
      result = vim.tbl_filter(function(entry)
        return type_of(entry) == memory_type
      end, result)
    end
    return result
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

  -- The type filter must reach retrieve_memories itself (source-level
  -- filtering), otherwise a target-type memory ranked below the top-N
  -- would be silently dropped before recall_memory ever sees it.
  lu.assertEquals('daily', self.retrieve_calls[1].memory_type)
end

function TestRecallMemoryExtra:testTypeFilterSurvivesKeywordFallback()
  -- Both searches must carry memory_type, and the fallback must use the
  -- resolved target session (all_sessions), not ctx.session.
  local calls = {}
  memory.retrieve_memories = function(query, session, limit, opts)
    table.insert(calls, {
      query = query,
      session = session,
      memory_type = opts and opts.memory_type,
    })
    return {}
  end

  tools.call('recall_memory', {
    query = 'alpha beta',
    memory_type = 'working',
    all_sessions = true,
  }, { session = SID })

  lu.assertEquals(2, #calls, 'expected main search + keyword fallback')
  for _, call in ipairs(calls) do
    lu.assertEquals('working', call.memory_type,
      'memory_type must be forwarded on every search')
    lu.assertNil(call.session,
      'all_sessions=true must send a nil session on every search, '
        .. 'including the keyword fallback')
  end
end

return TestRecallMemoryExtra


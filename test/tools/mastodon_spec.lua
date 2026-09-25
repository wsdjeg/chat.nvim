-- test/tools/mastodon_spec.lua
-- Tests for the mastodon tool. Fully offline:
--   - validation / dispatch errors (no network touched)
--   - helpers (_parse_toot_url, _strip_html)
--   - mocked HTTP via a fake vim.system (same pattern as providers_spec.lua)

local lu = require('luaunit')
local mastodon = require('chat.tools.mastodon')
local tools = require('chat.tools')

TestMastodon = {}

local real_vim_system = vim.system

function TestMastodon:tearDown()
  vim.system = real_vim_system
end

-- ============================
-- Fake vim.system (synchronous)
-- ============================

--- Install a fake vim.system that responds synchronously.
--- responder(cmd) -> { code = 0, stdout = "..." }
local function fake_system(responder)
  vim.system = function(cmd, _opts, cb)
    local out = responder(cmd)
    local handle = {}
    if cb then
      cb(out)
      return handle
    end
    function handle:wait()
      return out
    end
    return handle
  end
end

--- Extract the request URL from a curl command array (url is the last element).
local function cmd_url(cmd)
  return cmd[#cmd]
end

-- ============================
-- Sample API payloads
-- ============================

local SAMPLE_STATUS = {
  id = '109307870061423362',
  created_at = '2026-01-01T00:00:00.000Z',
  url = 'https://mastodon.social/@gargron/109307870061423362',
  content = '<p>Hello <a href="https://example.com">world</a>!</p><p>Second line</p>',
  spoiler_text = '',
  replies_count = 1,
  reblogs_count = 2,
  favourites_count = 3,
  account = {
    acct = 'gargron',
    display_name = 'Eugen Rochko',
    url = 'https://mastodon.social/@gargron',
  },
  media_attachments = {},
}

local SAMPLE_REPLY = {
  id = '999',
  created_at = '2026-01-01T01:00:00.000Z',
  url = 'https://mastodon.social/@someone/999',
  content = '<p>A reply</p>',
  replies_count = 0,
  reblogs_count = 0,
  favourites_count = 0,
  account = { acct = 'someone', display_name = '' },
  media_attachments = {},
}

-- ============================
-- Scheme Tests
-- ============================

function TestMastodon:testScheme()
  local scheme = mastodon.scheme()
  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'mastodon')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'action'))

  local props = scheme['function'].parameters.properties
  lu.assertNotNil(props.action)
  lu.assertNotNil(props.url)
  lu.assertNotNil(props.context)
  lu.assertNotNil(props.query)
  lu.assertNotNil(props.type)
  lu.assertNotNil(props.timeline)
  lu.assertNotNil(props['local'])
  lu.assertNotNil(props.instance)
  lu.assertNotNil(props.limit)
  lu.assertNotNil(props.access_token)
  lu.assertNotNil(props.timeout)
end

function TestMastodon:testSchemeValidated()
  local scheme = mastodon.scheme()
  local errors = tools.validate_scheme(scheme)
  lu.assertEquals(#errors, 0)
end

function TestMastodon:testIntroduction()
  lu.assertEquals(type(mastodon.introduction()), 'string')
  lu.assertNotEquals(mastodon.introduction(), '')
end

-- ============================
-- Registration Test
-- ============================

function TestMastodon:testRegistered()
  local available = tools.available_tools()
  local names = {}
  for _, tool in ipairs(available) do
    table.insert(names, tool['function'].name)
  end
  lu.assertTrue(
    vim.tbl_contains(names, 'mastodon'),
    'mastodon should be in available_tools'
  )
end

-- ============================
-- Info Tests
-- ============================

function TestMastodon:testInfoFetch()
  local info = mastodon.info(
    '{"action":"fetch","url":"https://mastodon.social/@gargron/123","context":true}',
    {}
  )
  lu.assertStrContains(info, 'mastodon fetch')
  lu.assertStrContains(info, 'https://mastodon.social/@gargron/123')
  lu.assertStrContains(info, 'context=true')
end

function TestMastodon:testInfoSearch()
  local info = mastodon.info(
    '{"action":"search","query":"neovim","type":"statuses"}',
    {}
  )
  lu.assertStrContains(info, 'mastodon search')
  lu.assertStrContains(info, '"neovim"')
  lu.assertStrContains(info, 'type=statuses')
end

function TestMastodon:testInfoTimeline()
  local info = mastodon.info('{"action":"timeline","timeline":"tag:neovim"}', {})
  lu.assertStrContains(info, 'mastodon timeline')
  lu.assertStrContains(info, 'tag:neovim')
end

function TestMastodon:testInfoInvalidJson()
  lu.assertEquals(mastodon.info('not json', {}), 'mastodon')
  lu.assertEquals(mastodon.info(nil, {}), 'mastodon')
end

-- ============================
-- Helper: _parse_toot_url
-- ============================

function TestMastodon:testParseTootUrl()
  local inst, id =
    mastodon._parse_toot_url('https://mastodon.social/@gargron/109307870061423362')
  lu.assertEquals(inst, 'https://mastodon.social')
  lu.assertEquals(id, '109307870061423362')
end

function TestMastodon:testParseTootUrlRemoteUser()
  local inst, id =
    mastodon._parse_toot_url('https://fosstodon.org/@user@mastodon.social/12345')
  lu.assertEquals(inst, 'https://fosstodon.org')
  lu.assertEquals(id, '12345')
end

function TestMastodon:testParseTootUrlTrailingSlashAndQuery()
  local inst, id =
    mastodon._parse_toot_url('https://mastodon.social/@gargron/12345/?x=1')
  lu.assertEquals(inst, 'https://mastodon.social')
  lu.assertEquals(id, '12345')
end

function TestMastodon:testParseTootUrlHttp()
  local inst, id = mastodon._parse_toot_url('http://localhost:3000/@dev/42')
  lu.assertEquals(inst, 'http://localhost:3000')
  lu.assertEquals(id, '42')
end

function TestMastodon:testParseTootUrlInvalid()
  lu.assertNil(mastodon._parse_toot_url('https://mastodon.social/@gargron'))
  lu.assertNil(mastodon._parse_toot_url('https://mastodon.social/users/123'))
  lu.assertNil(mastodon._parse_toot_url('not a url'))
  lu.assertNil(mastodon._parse_toot_url(''))
  lu.assertNil(mastodon._parse_toot_url(nil))
  lu.assertNil(mastodon._parse_toot_url(42))
end

-- ============================
-- Helper: _strip_html
-- ============================

function TestMastodon:testStripHtmlParagraphs()
  local text = mastodon._strip_html(
    '<p>Hello <a href="https://example.com">world</a>!</p><p>Second line</p>'
  )
  lu.assertEquals(text, 'Hello world!\n\nSecond line')
end

function TestMastodon:testStripHtmlBr()
  lu.assertEquals(mastodon._strip_html('a<br />b<br>c'), 'a\nb\nc')
end

function TestMastodon:testStripHtmlEntities()
  lu.assertEquals(
    mastodon._strip_html('&lt;b&gt; &amp; &quot;q&quot;'),
    '<b> & "q"'
  )
end

function TestMastodon:testStripHtmlEmpty()
  lu.assertEquals(mastodon._strip_html(nil), '')
  lu.assertEquals(mastodon._strip_html(''), '')
end

-- ============================
-- Validation Tests (no network)
-- ============================

function TestMastodon:testMissingAction()
  local r = mastodon.mastodon({}, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'action')
end

function TestMastodon:testUnknownAction()
  local r = mastodon.mastodon({ action = 'post' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'unknown action')
end

function TestMastodon:testInvalidTimeout()
  local r = mastodon.mastodon({ action = 'fetch', url = 'x', timeout = 0 }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'timeout')
  r = mastodon.mastodon({ action = 'fetch', url = 'x', timeout = 'fast' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'timeout')
end

function TestMastodon:testFetchMissingUrlAndId()
  local r = mastodon.mastodon({ action = 'fetch' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'fetch requires')
end

function TestMastodon:testFetchInvalidUrl()
  local r = mastodon.mastodon({ action = 'fetch', url = 'https://example.com' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'parse toot URL')
end

function TestMastodon:testFetchInvalidId()
  local r = mastodon.mastodon(
    { action = 'fetch', id = 'not-numeric', instance = 'https://mastodon.social' },
    {}
  )
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'numeric status ID')
end

function TestMastodon:testSearchMissingQuery()
  local r = mastodon.mastodon({ action = 'search' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'query')
end

function TestMastodon:testSearchInvalidType()
  local r = mastodon.mastodon({ action = 'search', query = 'x', type = 'toots' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'type')
end

function TestMastodon:testSearchInvalidLimit()
  local r = mastodon.mastodon({ action = 'search', query = 'x', limit = 0 }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'limit')
end

function TestMastodon:testTimelineMissing()
  local r = mastodon.mastodon({ action = 'timeline' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'timeline')
end

function TestMastodon:testTimelineInvalidFormat()
  local r = mastodon.mastodon({ action = 'timeline', timeline = 'home' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'invalid timeline')
end

function TestMastodon:testTimelineTagEmpty()
  local r = mastodon.mastodon({ action = 'timeline', timeline = 'tag:' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'invalid timeline')
end

-- ============================
-- Mocked HTTP Tests
-- ============================

function TestMastodon:testFetchByUrlMocked()
  fake_system(function(cmd)
    local url = cmd_url(cmd)
    if url:find('/api/v1/statuses/109307870061423362/context') then
      return {
        code = 0,
        stdout = vim.json.encode({
          ancestors = { SAMPLE_REPLY },
          descendants = { SAMPLE_STATUS },
        }),
      }
    end
    if url:find('/api/v1/statuses/109307870061423362') then
      return { code = 0, stdout = vim.json.encode(SAMPLE_STATUS) }
    end
    return { code = 1, stderr = 'unexpected url: ' .. url }
  end)

  local r = mastodon.mastodon({
    action = 'fetch',
    url = 'https://mastodon.social/@gargron/109307870061423362',
    context = true,
  }, {})

  lu.assertNil(r.error)
  lu.assertStrContains(r.content, '@gargron (Eugen Rochko)')
  lu.assertStrContains(r.content, 'Hello world!')
  lu.assertStrContains(r.content, 'Second line')
  lu.assertStrContains(r.content, 'replies=1 boosts=2 favorites=3')
  lu.assertStrContains(r.content, 'URL: https://mastodon.social/@gargron/109307870061423362')
  lu.assertStrContains(r.content, 'Thread ancestors (1)')
  lu.assertStrContains(r.content, 'Thread replies (1)')
end

function TestMastodon:testFetchBoostMocked()
  local boost = {
    id = '111',
    url = 'https://mastodon.social/@a/111',
    created_at = '2026-01-01T00:00:00.000Z',
    content = '',
    reblog = SAMPLE_STATUS,
    replies_count = 0,
    reblogs_count = 0,
    favourites_count = 0,
    account = { acct = 'booster', display_name = '' },
    media_attachments = {},
  }
  fake_system(function(cmd)
    local url = cmd_url(cmd)
    if url:find('/api/v1/statuses/111') then
      return { code = 0, stdout = vim.json.encode(boost) }
    end
    return { code = 1, stderr = 'unexpected url: ' .. url }
  end)

  local r = mastodon.mastodon({
    action = 'fetch',
    url = 'https://mastodon.social/@booster/111',
  }, {})

  lu.assertNil(r.error)
  lu.assertStrContains(r.content, '@booster boosted @gargron:')
  lu.assertStrContains(r.content, 'Hello world!')
end

function TestMastodon:testFetchNotFoundMocked()
  fake_system(function()
    return { code = 0, stdout = vim.json.encode({ error = 'Record not found' }) }
  end)

  local r = mastodon.mastodon({
    action = 'fetch',
    url = 'https://mastodon.social/@gargron/404404404',
  }, {})

  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'Record not found')
end

function TestMastodon:testFetchByIdUsesConfiguredInstance()
  fake_system(function(cmd)
    local url = cmd_url(cmd)
    lu.assertStrContains(url, 'https://fosstodon.org/api/v1/statuses/12345')
    return { code = 0, stdout = vim.json.encode(SAMPLE_STATUS) }
  end)

  local r = mastodon.mastodon({
    action = 'fetch',
    id = '12345',
    instance = 'fosstodon.org',
  }, {})

  lu.assertNil(r.error)
end

function TestMastodon:testSearchMocked()
  fake_system(function(cmd)
    local url = cmd_url(cmd)
    if
      url:find('https://fosstodon%.org/api/v2/search')
      and url:find('q=neovim')
      and url:find('type=accounts')
    then
      return {
        code = 0,
        stdout = vim.json.encode({
          statuses = {},
          accounts = {
            {
              acct = 'neovim@fosstodon.org',
              display_name = 'Neovim',
              note = '<p>Official account</p>',
              url = 'https://fosstodon.org/@neovim',
              followers_count = 100,
              following_count = 10,
              statuses_count = 500,
            },
          },
          hashtags = {
            { name = 'neovim', url = 'https://fosstodon.org/tags/neovim', history = { { uses = '42' } } },
          },
        }),
      }
    end
    return { code = 1, stderr = 'unexpected url: ' .. url }
  end)

  local r = mastodon.mastodon({
    action = 'search',
    query = 'neovim',
    type = 'accounts',
    instance = 'https://fosstodon.org',
  }, {})

  lu.assertNil(r.error)
  lu.assertStrContains(r.content, 'Mastodon search results for "neovim"')
  lu.assertStrContains(r.content, '@neovim@fosstodon.org (Neovim)')
  lu.assertStrContains(r.content, 'followers=100 following=10 posts=500')
  lu.assertStrContains(r.content, 'bio: Official account')
end

function TestMastodon:testSearchHashtagUses()
  fake_system(function()
    return {
      code = 0,
      stdout = vim.json.encode({
        statuses = {},
        accounts = {},
        hashtags = {
          { name = 'neovim', url = 'https://mastodon.social/tags/neovim', history = { { uses = '42' } } },
        },
      }),
    }
  end)

  local r = mastodon.mastodon({
    action = 'search',
    query = 'neovim',
    type = 'hashtags',
  }, {})

  lu.assertNil(r.error)
  lu.assertStrContains(r.content, '#neovim (uses today: 42)')
end

function TestMastodon:testSearchNoResults()
  fake_system(function()
    return {
      code = 0,
      stdout = vim.json.encode({ statuses = {}, accounts = {}, hashtags = {} }),
    }
  end)

  local r = mastodon.mastodon({ action = 'search', query = 'zzz' }, {})
  lu.assertNil(r.error)
  lu.assertStrContains(r.content, 'No results found')
end

function TestMastodon:testSearchAuthErrorHasHint()
  fake_system(function()
    return {
      code = 0,
      stdout = vim.json.encode({ error = 'The access token is invalid' }),
    }
  end)

  local r = mastodon.mastodon({ action = 'search', query = 'x' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'access token')
  lu.assertStrContains(r.error, 'Hint')
end

function TestMastodon:testSearchPassesTokenHeader()
  local seen_headers = {}
  fake_system(function(cmd)
    for i, part in ipairs(cmd) do
      if part == '-H' and cmd[i + 1] then
        table.insert(seen_headers, cmd[i + 1])
      end
    end
    return {
      code = 0,
      stdout = vim.json.encode({ statuses = {}, accounts = {}, hashtags = {} }),
    }
  end)

  local r = mastodon.mastodon({
    action = 'search',
    query = 'x',
    access_token = 'tok123',
  }, {})

  lu.assertNil(r.error)
  lu.assertTrue(
    vim.tbl_contains(seen_headers, 'Authorization: Bearer tok123'),
    'Authorization header should be sent when access_token is provided'
  )
end

function TestMastodon:testTimelineTagMocked()
  fake_system(function(cmd)
    local url = cmd_url(cmd)
    if url:find('/api/v1/timelines/tag/neovim') then
      lu.assertStrContains(url, 'limit=5')
      return { code = 0, stdout = vim.json.encode({ SAMPLE_STATUS, SAMPLE_REPLY }) }
    end
    return { code = 1, stderr = 'unexpected url: ' .. url }
  end)

  local r = mastodon.mastodon({
    action = 'timeline',
    timeline = 'tag:neovim',
    limit = 5,
  }, {})

  lu.assertNil(r.error)
  lu.assertStrContains(r.content, 'tag:neovim timeline')
  lu.assertStrContains(r.content, '2 toots')
  lu.assertStrContains(r.content, 'Hello world!')
end

function TestMastodon:testTimelinePublicLocalFlag()
  fake_system(function(cmd)
    local url = cmd_url(cmd)
    if url:find('/api/v1/timelines/public') then
      lu.assertStrContains(url, 'local=true')
      lu.assertStrContains(url, 'limit=20')
      return { code = 0, stdout = vim.json.encode({}) }
    end
    return { code = 1, stderr = 'unexpected url: ' .. url }
  end)

  local r = mastodon.mastodon({
    action = 'timeline',
    timeline = 'public',
    ['local'] = true,
  }, {})

  lu.assertNil(r.error)
  lu.assertStrContains(r.content, 'Timeline is empty')
end

function TestMastodon:testTimelineEmpty()
  fake_system(function()
    return { code = 0, stdout = vim.json.encode({}) }
  end)

  local r = mastodon.mastodon({ action = 'timeline', timeline = 'public' }, {})
  lu.assertNil(r.error)
  lu.assertStrContains(r.content, 'Timeline is empty')
end

function TestMastodon:testTimelineNetworkError()
  fake_system(function()
    return { code = 7, stderr = 'connection refused' }
  end)

  local r = mastodon.mastodon({ action = 'timeline', timeline = 'public' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'curl exit code 7')
end

function TestMastodon:testTimelineInvalidJson()
  fake_system(function()
    return { code = 0, stdout = 'not json at all' }
  end)

  local r = mastodon.mastodon({ action = 'timeline', timeline = 'public' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'Failed to parse')
end

-- ============================
-- Tool Call Dispatch Test
-- ============================

function TestMastodon:testToolCallDispatch()
  local r = tools.call('mastodon', { action = 'bogus' }, {})
  lu.assertNotNil(r.error)
  lu.assertStrContains(r.error, 'unknown action')
end

return TestMastodon


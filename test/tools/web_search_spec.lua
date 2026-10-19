local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local web_search = require('chat.tools.web_search')
local curl = require('chat.curl')

local function mock_response(stdout, code)
  curl.is_available = function() return true end
  curl.build_request = function(opts)
    return { 'echo', opts and opts.method or 'GET' }
  end
  vim.system = function(cmd, opts)
    return {
      wait = function()
        return { stdout = stdout, stderr = '', code = code or 0 }
      end,
    }
  end
end

TestWebSearch = {}

function TestWebSearch:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.config.api_key = nil
  self._orig_avail = curl.is_available
  self._orig_build = curl.build_request
  self._orig_system = vim.system
end

function TestWebSearch:tearDown()
  curl.is_available = self._orig_avail
  curl.build_request = self._orig_build
  vim.system = self._orig_system
end

function TestWebSearch:testMissingQuery()
  local result = tools.call('web_search', {}, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Query is required')
end

function TestWebSearch:testInvalidEngine()
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'bing',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Engine must be either')
end

function TestWebSearch:testCurlUnavailable()
  curl.is_available = function() return false end
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'firecrawl',
    api_key = 'k',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'curl is not installed')
end

function TestWebSearch:testFirecrawlMissingKey()
  curl.is_available = function() return true end
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'firecrawl',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Firecrawl API key is required')
end

function TestWebSearch:testGoogleMissingKey()
  curl.is_available = function() return true end
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'google',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Google API key is required')
end

function TestWebSearch:testGoogleMissingCx()
  curl.is_available = function() return true end
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'google',
    api_key = 'k',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cx')
end

function TestWebSearch:testSerpapiMissingKey()
  curl.is_available = function() return true end
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'serpapi',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'SerpAPI key is required')
end

function TestWebSearch:testFirecrawlSuccess()
  mock_response(vim.json.encode({
    success = true,
    data = {
      web = {
        { title = 'T1', url = 'http://u1', description = 'd1', position = 1 },
      },
      images = { { url = 'i1' } },
      news = { { title = 'n1' } },
    },
  }))
  local result = tools.call('web_search', {
    query = 'test query',
    engine = 'firecrawl',
    api_key = 'fc-key',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Firecrawl search results')
  lu.assertStrContains(result.content, 'T1')
  lu.assertStrContains(result.content, 'Images: 1 results')
  lu.assertStrContains(result.content, 'News: 1 results')
end

function TestWebSearch:testGoogleSuccess()
  mock_response(vim.json.encode({
    items = {
      { title = 'G1', link = 'http://g1', snippet = 's1', displayLink = 'd' },
    },
    searchInformation = {
      formattedSearchTime = '0.5',
      formattedTotalResults = '100',
    },
  }))
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'google',
    api_key = 'g-key',
    cx = 'cx-id',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'Google search results')
  lu.assertStrContains(result.content, 'G1')
end

function TestWebSearch:testSerpapiSuccess()
  mock_response(vim.json.encode({
    organic_results = {
      { title = 'S1', link = 'http://s1', snippet = 's1', displayed_url = 'd' },
    },
    answer_box = { title = 'AB', snippet = 'abs', answer = 'aaa' },
    knowledge_graph = { title = 'KG', description = 'kgd' },
    related_questions = { { question = 'Q1' } },
  }))
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'serpapi',
    api_key = 's-key',
    serpapi_engine = 'bing',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertStrContains(result.content, 'SerpAPI search results')
  lu.assertStrContains(result.content, 'S1')
  lu.assertStrContains(result.content, 'Answer Box')
  lu.assertStrContains(result.content, 'Knowledge Graph')
  lu.assertStrContains(result.content, 'Related Questions')
end

function TestWebSearch:testFirecrawlApiError()
  mock_response(vim.json.encode({ success = false, error = 'bad request' }))
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'firecrawl',
    api_key = 'k',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'bad request')
end

function TestWebSearch:testGoogleApiError()
  mock_response(vim.json.encode({ error = { message = 'google error' } }))
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'google',
    api_key = 'k',
    cx = 'c',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'google error')
end

function TestWebSearch:testSerpapiApiError()
  mock_response(vim.json.encode({ error = 'serpapi error' }))
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'serpapi',
    api_key = 'k',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'serpapi error')
end

function TestWebSearch:testParseFailure()
  mock_response('not-json', 0)
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'firecrawl',
    api_key = 'k',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Failed to parse API response')
end

function TestWebSearch:testNonZeroExit()
  mock_response('', 7)
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'firecrawl',
    api_key = 'k',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'API request failed')
end

function TestWebSearch:testApiKeyFromConfig()
  config.setup({
    api_key = {
      firecrawl = 'cfg-fc-key',
    },
  })
  mock_response(vim.json.encode({ success = true, data = { web = {} } }))
  local result = tools.call('web_search', {
    query = 'test',
    engine = 'firecrawl',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
end

function TestWebSearch:testInfoDefault()
  local info = web_search.info('not json', { cwd = self.cwd })
  lu.assertEquals('web_search', info)
end

function TestWebSearch:testInfoFull()
  local info = web_search.info(
    vim.json.encode({
      query = 'neovim',
      engine = 'serpapi',
      limit = 10,
      serpapi_engine = 'bing',
    }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'web_search "neovim"')
  lu.assertStrContains(info, 'engine=serpapi')
  lu.assertStrContains(info, 'limit=10')
  lu.assertStrContains(info, 'serpapi_engine=bing')
end

function TestWebSearch:testScheme()
  local scheme = web_search.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('web_search', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.properties.engine)
end

return TestWebSearch

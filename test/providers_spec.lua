-- Coverage for lua/chat/providers/*.lua
-- Uses the test/job.lua mock to capture request construction without network.
local lu = require('luaunit')
local job = require('job')
local config = require('chat.config')
local sessions = require('chat.sessions')

-- [modname] = api_key field name
local ALL_PROVIDERS = {
  'deepseek',
  'aliyuncs',
  'aliyuncs_coding_plan',
  'aliyuncs_coding_plan_anthropic',
  'anthropic',
  'baidu',
  'bigmodel',
  'cherryin',
  'gemini',
  'github',
  'longcat',
  'moonshot',
  'ollama',
  'openai',
  'openrouter',
  'qwen',
  'siliconflow',
  'tencent',
  'volcengine',
  'volcengine_coding_plan',
  'xiaomi',
  'xiaomi_token_plan',
  'yuanjing',
}

-- Provider request endpoint per module (used to verify curl cmd)
local URLS = {
  deepseek = 'https://api.deepseek.com/v1/chat/completions',
  aliyuncs = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
  aliyuncs_coding_plan = 'https://coding.dashscope.aliyuncs.com/v1/chat/completions',
  aliyuncs_coding_plan_anthropic = 'https://coding.dashscope.aliyuncs.com/apps/anthropic/v1/messages',
  anthropic = 'https://api.anthropic.com/v1/messages',
  baidu = 'https://qianfan.baidubce.com/v2/chat/completions',
  bigmodel = 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
  cherryin = 'https://open.cherryin.ai/v1/chat/completions',
  gemini = ':streamGenerateContent?',
  github = 'https://models.github.ai/inference/v1/chat/completions',
  longcat = 'https://api.longcat.chat/openai/v1/chat/completions',
  moonshot = 'https://api.moonshot.cn/v1/chat/completions',
  ollama = '/v1/chat/completions',
  openai = 'https://api.openai.com/v1/chat/completions',
  openrouter = 'https://openrouter.ai/api/v1/chat/completions',
  qwen = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
  siliconflow = 'https://api.siliconflow.cn/v1/chat/completions',
  tencent = 'https://api.hunyuan.cloud.tencent.com/v1/chat/completions',
  volcengine = 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
  volcengine_coding_plan = 'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
  xiaomi = 'https://api.xiaomimimo.com/v1/chat/completions',
  xiaomi_token_plan = 'https://token-plan-sgp.xiaomimimo.com/v1/chat/completions',
  yuanjing = 'https://maas-api.ai-yuanjing.com/openapi/compatible-mode/v1/chat/completions',
}

-- Providers with static model lists
local STATIC_LIST_PROVIDERS = {
  'anthropic',
  'bigmodel',
  'deepseek',
  'longcat',
  'tencent',
  'volcengine',
  'volcengine_coding_plan',
  'xiaomi',
  'xiaomi_token_plan',
  'yuanjing',
  'aliyuncs_coding_plan',
  'aliyuncs_coding_plan_anthropic',
}

-- Providers that fetch models dynamically via vim.system callback
-- [modname] = JSON payload shape for the fake response
local DYNAMIC_PAYLOADS = {
  openai = '{"data":[{"id":"gpt-test-1"},{"id":"gpt-test-2"}]}',
  aliyuncs = '{"data":[{"id":"qwen-max"}]}',
  baidu = '{"data":[{"id":"ernnie-4"}]}',
  siliconflow = '{"data":[{"id":"Qwen/Qwen3"}]}',
  moonshot = '{"data":[{"id":"kimi-latest"}]}',
  openrouter = '{"data":[{"id":"openai/gpt-4o"}]}',
  cherryin = '{"models":[{"name":"gemini-2.5-pro"}]}',
  github = '[{"id":"openai/gpt-5"},{"id":"meta/llama-4"}]',
  gemini = '{"models":['
    .. '{"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]},'
    .. '{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}'
    .. ']}',
}

TestProviders = {}

local real_vim_system = vim.system

function TestProviders:setUp()
  job.reset()
  -- Ensure every provider has a key so header concatenation works
  for _, name in ipairs(ALL_PROVIDERS) do
    config.config.api_key[name] = name .. '-test-key'
  end
  self.session_id = sessions.new()
  sessions.set_session_model(self.session_id, 'unit-test-model')
end

function TestProviders:tearDown()
  vim.system = real_vim_system
  config.config.api_key.ollama_fake = nil
end

local function load_fresh(modname)
  package.loaded['chat.providers.' .. modname] = nil
  return require('chat.providers.' .. modname)
end

--- Install a fake vim.system that responds synchronously
--- responder(cmd) -> { code = 0, stdout = "..." }
local function fake_system(responder)
  vim.system = function(cmd, opts, cb)
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

--- Build a request through a provider and return (jobid, j, body)
--- Creates a fresh session per call (request marks session in_progress)
local function do_request(mod, messages, model)
  local sid = sessions.new()
  sessions.set_session_model(sid, model or 'unit-test-model')
  local provider = require('chat.providers.' .. mod)
  local jobid = provider.request({
    session = sid,
    messages = messages
      or {
        { role = 'user', content = 'hello provider' },
      },
    on_stdout = function() end,
    on_stderr = function() end,
    on_exit = function() end,
  })
  lu.assertTrue(jobid > 0, mod .. ' should return positive jobid')
  local j = job.jobs[jobid]
  lu.assertNotNil(j, mod .. ' should record a job')
  lu.assertNotNil(j.stdin[1], mod .. ' should send body via stdin')
  local ok, body = pcall(vim.json.decode, j.stdin[1])
  lu.assertTrue(ok, mod .. ' stdin body should be valid JSON')
  -- Simulate job completion so the (second-precision) session id is not
  -- stuck in-progress for the next do_request call
  require('chat.sessions.progress').on_progress_exit(jobid, 0)
  return jobid, j, body
end

function TestProviders:test_all_providers_build_request()
  for _, mod in ipairs(ALL_PROVIDERS) do
    local _, j, body = do_request(mod)
    -- URL present in cmd
    local cmd_str = table.concat(j.cmd, ' ')
    lu.assertStrContains(cmd_str, URLS[mod], false, mod .. ' should target its endpoint')
    -- model + messages
    -- model: in request body (most) or URL path (gemini)
    if mod == 'gemini' then
      lu.assertStrContains(cmd_str, 'unit-test-model', false, mod .. ' model in URL')
    else
      lu.assertEquals(body.model, 'unit-test-model', mod .. ' body model')
    end
    if body.messages then
      lu.assertEquals(#body.messages, 1, mod .. ' body messages count')
      -- anthropic-protocol providers wrap content in blocks
      local c = body.messages[1].content
      if type(c) == 'table' then
        c = c[1].text
      end
      lu.assertEquals(c, 'hello provider', mod .. ' body content')
    end
    -- streaming enabled (gemini streams via URL suffix, not body.stream)
    if mod ~= 'gemini' then
      lu.assertEquals(body.stream, true, mod .. ' body stream')
    end
  end
end

function TestProviders:test_openai_compat_auth_headers()
  for _, mod in ipairs({
    'deepseek',
    'aliyuncs',
    'baidu',
    'bigmodel',
    'cherryin',
    'github',
    'longcat',
    'moonshot',
    'openai',
    'openrouter',
    'qwen',
    'siliconflow',
    'tencent',
    'volcengine',
    'volcengine_coding_plan',
    'xiaomi',
    'xiaomi_token_plan',
    'yuanjing',
    'aliyuncs_coding_plan',
  }) do
    local _, j = do_request(mod)
    local cmd_str = table.concat(j.cmd, ' ')
    lu.assertStrContains(cmd_str, 'Bearer ' .. mod .. '-test-key', false, mod .. ' bearer auth')
    lu.assertStrContains(cmd_str, 'POST', false, mod .. ' uses POST')
  end
end

function TestProviders:test_anthropic_protocol_headers()
  for _, mod in ipairs({ 'anthropic', 'aliyuncs_coding_plan_anthropic' }) do
    local _, j, body = do_request(mod)
    local cmd_str = table.concat(j.cmd, ' ')
    lu.assertStrContains(cmd_str, 'x-api-key: ' .. (mod == 'anthropic' and 'anthropic' or 'aliyuncs_coding_plan') .. '-test-key')
    lu.assertStrContains(cmd_str, 'anthropic-version: 2023-06-01')
    lu.assertEquals(body.max_tokens, 4096, mod .. ' max_tokens')
    -- messages converted to anthropic format
    lu.assertEquals(body.messages[1].role, 'user')
    lu.assertEquals(body.messages[1].content[1].type, 'text')
    -- protocol marker
    local provider = require('chat.providers.' .. mod)
    lu.assertEquals(provider.protocol, 'anthropic', mod .. ' protocol field')
  end
end

function TestProviders:test_gemini_request_conversion()
  local provider = require('chat.providers.gemini')
  lu.assertEquals(provider.protocol, 'gemini')

  local _, j, body = do_request('gemini', {
    { role = 'system', content = 'be nice' },
    { role = 'user', content = 'question' },
    { role = 'assistant', content = 'answer' },
    { role = 'tool', content = 'tool output' },
  })
  local cmd_str = table.concat(j.cmd, ' ')
  lu.assertStrContains(cmd_str, 'key=gemini-test-key')
  lu.assertStrContains(cmd_str, 'unit-test-model:streamGenerateContent')

  lu.assertEquals(#body.contents, 3, 'system not in contents')
  lu.assertEquals(body.contents[1].role, 'user')
  lu.assertEquals(body.contents[2].role, 'model', 'assistant -> model role')
  lu.assertEquals(body.contents[3].role, 'user', 'tool -> user role')
  lu.assertEquals(body.systemInstruction.parts[1].text, 'be nice')
  lu.assertEquals(body.generationConfig.maxOutputTokens, 8192)
  lu.assertTrue(vim.tbl_contains(j.cmd, '-X'), 'gemini POST method')

  -- gemini sends body without the closing-stdin nil on anthropic path; ensure stdin[2]==nil
  lu.assertNil(j.stdin[2])
end

function TestProviders:test_gemini_convert_tools()
  local provider = require('chat.providers.gemini')
  local converted = provider._convert_tools({
    { type = 'other' },
    {
      type = 'function',
      ['function'] = {
        name = 'read_file',
        description = 'Read a file',
        parameters = { type = 'object' },
      },
    },
  })
  lu.assertEquals(#converted, 1, 'non-function tools skipped')
  lu.assertEquals(converted[1].functionDeclarations[1].name, 'read_file')
  lu.assertEquals(converted[1].functionDeclarations[1].description, 'Read a file')
end

function TestProviders:test_anthropic_convert_tools()
  local provider = require('chat.providers.anthropic')
  local converted = provider._convert_tools({
    { type = 'other' },
    {
      type = 'function',
      ['function'] = { name = 'git_add', description = 'Stage', parameters = { type = 'object' } },
    },
  })
  lu.assertEquals(#converted, 1)
  lu.assertEquals(converted[1].name, 'git_add')
  lu.assertEquals(converted[1].input_schema.type, 'object')
end

function TestProviders:test_static_available_models()
  for _, mod in ipairs(STATIC_LIST_PROVIDERS) do
    local provider = require('chat.providers.' .. mod)
    local models = provider.available_models()
    lu.assertTrue(#models > 0, mod .. ' has static models')
    lu.assertEquals(type(models[1]), 'string')
  end
end

function TestProviders:test_dynamic_available_models_success()
  for mod, payload in pairs(DYNAMIC_PAYLOADS) do
    local provider = load_fresh(mod)
    local calls = {}
    fake_system(function(cmd)
      table.insert(calls, table.concat(cmd, ' '))
      return { code = 0, stdout = payload }
    end)
    local models = provider.available_models()
    lu.assertTrue(#calls >= 1, mod .. ' should fetch models')
    if mod == 'gemini' then
      lu.assertEquals(models, { 'gemini-2.5-pro' }, 'gemini filters non-generateContent')
    elseif mod == 'github' then
      lu.assertEquals(models, { 'openai/gpt-5', 'meta/llama-4' })
    elseif mod == 'cherryin' then
      lu.assertEquals(models, { 'gemini-2.5-pro' })
    else
      lu.assertTrue(#models >= 1, mod .. ' parsed models')
    end
    -- Second call is served from cache (no new fetch)
    local calls_before = #calls
    provider.available_models()
    lu.assertEquals(#calls, calls_before, mod .. ' caches models fetch')
  end
end

function TestProviders:test_dynamic_available_models_error_code()
  local provider = load_fresh('openai')
  fake_system(function()
    return { code = 22, stdout = '' }
  end)
  local models = provider.available_models()
  lu.assertEquals(models, {}, 'failed fetch returns empty list')
end

function TestProviders:test_dynamic_available_models_invalid_json()
  local provider = load_fresh('aliyuncs')
  fake_system(function()
    return { code = 0, stdout = 'not json{{{' }
  end)
  lu.assertEquals(provider.available_models(), {}, 'invalid JSON tolerated')
end

function TestProviders:test_dynamic_available_models_no_api_key()
  config.config.api_key.openai = nil
  local provider = load_fresh('openai')
  local called = false
  fake_system(function()
    called = true
    return { code = 0, stdout = '{"data":[]}' }
  end)
  lu.assertEquals(provider.available_models(), {}, 'no key -> no fetch')
  lu.assertFalse(called)
  config.config.api_key.openai = 'openai-test-key'
end

function TestProviders:test_qwen_available_models_pagination()
  local provider = load_fresh('qwen')
  local fetched_pages = {}
  fake_system(function(cmd)
    local url = table.concat(cmd, ' ')
    table.insert(fetched_pages, url)
    if url:find('page_no=2') then
      return { code = 0, stdout = '{"output":{"total":401,"models":[{"model":"q-page2"}]}}' }
    elseif url:find('page_no=3') then
      return { code = 0, stdout = '{"output":{"total":401,"models":[{"model":"q-page3"}]}}' }
    end
    return { code = 0, stdout = '{"output":{"total":401,"models":[{"model":"q-page1"}]}}' }
  end)
  local models = provider.available_models()
  -- page_size = 200, total = 401 -> pages 1,2,3
  lu.assertEquals(#fetched_pages, 3, 'should fetch 3 pages')
  lu.assertEquals(models, { 'q-page1', 'q-page2', 'q-page3' })
end

function TestProviders:test_qwen_no_pagination_when_small_total()
  local provider = load_fresh('qwen')
  local fetch_count = 0
  fake_system(function()
    fetch_count = fetch_count + 1
    return { code = 0, stdout = '{"output":{"total":10,"models":[{"model":"q-only"}]}}' }
  end)
  local models = provider.available_models()
  lu.assertEquals(fetch_count, 1, 'single page when total <= page_size')
  lu.assertEquals(models, { 'q-only' })
end

function TestProviders:test_ollama_available_models_sync()
  local provider = load_fresh('ollama')
  fake_system(function()
    return { code = 0, stdout = '{"models":[{"name":"llama3"},{"name":"qwen2"}]}' }
  end)
  local models = provider.available_models()
  lu.assertEquals(models, { 'llama3', 'qwen2' })
end

function TestProviders:test_ollama_available_models_failure()
  local provider = load_fresh('ollama')
  fake_system(function()
    return { code = 7, stdout = '' }
  end)
  lu.assertEquals(provider.available_models(), {}, 'connection refused -> empty')
end

function TestProviders:test_ollama_custom_host()
  config.config.ollama_host = 'http://127.0.0.1:1'
  local _, j = do_request('ollama')
  local cmd_str = table.concat(j.cmd, ' ')
  lu.assertStrContains(cmd_str, 'http://127.0.0.1:1/v1/chat/completions')
  config.config.ollama_host = nil
end

function TestProviders:test_deepseek_max_tokens_per_model()
  local _, _, body = do_request('deepseek', nil, 'deepseek-v4-pro')
  lu.assertEquals(body.max_tokens, 384 * 1024)

  _, _, body = do_request('deepseek', nil, 'unknown-model')
  lu.assertEquals(body.max_tokens, 4096, 'default max_tokens for unknown model')
end

function TestProviders:test_volcengine_coding_plan_flags()
  local _, j, body = do_request('volcengine_coding_plan', nil, 'glm-5.2')
  lu.assertEquals(body.max_tokens, 128000)
  lu.assertEquals(body.tool_stream, true)
  lu.assertStrContains(table.concat(j.cmd, ' '), '-N')
  lu.assertStrContains(table.concat(j.cmd, ' '), '--tcp-nodelay')

  _, _, body = do_request('volcengine_coding_plan', nil, 'mystery')
  lu.assertEquals(body.max_tokens, 4096)
end

function TestProviders:test_yuanjing_chat_template_kwargs()
  local _, _, body = do_request('yuanjing')
  lu.assertEquals(body.chat_template_kwargs.enable_thinking, true)
end

function TestProviders:test_enable_thinking_providers()
  for _, mod in ipairs({
    'aliyuncs',
    'baidu',
    'bigmodel',
    'longcat',
    'openai',
    'qwen',
    'siliconflow',
    'tencent',
    'volcengine',
    'aliyuncs_coding_plan',
  }) do
    local _, _, body = do_request(mod)
    lu.assertEquals(body.enable_thinking, true, mod .. ' enable_thinking')
  end
end

function TestProviders:test_thinking_type_providers()
  for _, mod in ipairs({
    'cherryin',
    'deepseek',
    'moonshot',
    'volcengine_coding_plan',
    'xiaomi',
    'xiaomi_token_plan',
  }) do
    local _, _, body = do_request(mod)
    lu.assertEquals(body.thinking.type, 'enabled', mod .. ' thinking.type')
  end
end

function TestProviders:test_request_callbacks_wired()
  local stdout_hit, stderr_hit, exit_hit = false, false, false
  local provider = require('chat.providers.deepseek')
  local jobid = provider.request({
    session = self.session_id,
    messages = { { role = 'user', content = 'x' } },
    on_stdout = function()
      stdout_hit = true
    end,
    on_stderr = function()
      stderr_hit = true
    end,
    on_exit = function()
      exit_hit = true
    end,
  })
  job.emit_stdout(jobid, 'line')
  job.emit_stderr(jobid, 'err')
  job.emit_exit(jobid, 0)
  lu.assertTrue(stdout_hit and stderr_hit and exit_hit, 'callbacks wired to job opts')
end

function TestProviders:test_gemini_tools_in_body()
  local _, _, body = do_request('gemini')
  lu.assertNotNil(body.tools, 'gemini converts available tools')
end

return TestProviders


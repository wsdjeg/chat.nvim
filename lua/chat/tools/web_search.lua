local M = {}

local config = require('chat.config')

-- Cache curl availability check
local curl_available = nil
local function is_curl_available()
  if curl_available == nil then
    local curl_check = vim.fn.system({ 'curl', '--version' })
    curl_available = vim.v.shell_error == 0
  end
  return curl_available
end

---@class ChatToolsWebSearchAction
---@field query string
---@field limit? integer
---@field scrape_options? table
---@field api_key? string
---@field timeout? integer

---@param action ChatToolsWebSearchAction
---@param ctx ChatContext
function M.web_search(action, ctx)
  -- Parameter validation
  if not action.query or type(action.query) ~= 'string' or action.query == '' then
    return {
      error = 'Query is required and must be a non-empty string.',
    }
  end

  -- Check if curl is available
  if not is_curl_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  -- Get API key
  local api_key = action.api_key
  if not api_key or api_key == '' then
    -- Try to get from config
    if type(config.config.api_key) == 'table' and config.config.api_key.firecrawl then
      api_key = config.config.api_key.firecrawl
    elseif type(config.config.api_key) == 'string' and config.config.api_key ~= '' then
      api_key = config.config.api_key
    end
  end

  if not api_key or api_key == '' then
    return {
      error = 'Firecrawl API key is required. Please set it in config.api_key.firecrawl or provide as parameter.',
    }
  end

  -- Build request payload
  local payload = {
    query = action.query,
    limit = action.limit or 5,
  }
  if action.scrape_options then
    payload.scrape_options = action.scrape_options
  end

  local payload_json = vim.json.encode(payload)

  -- Build curl command
  local cmd = { 'curl' }
  table.insert(cmd, '-s')
  table.insert(cmd, '-L')
  table.insert(cmd, '--compressed')
  
  -- Timeout
  local timeout = action.timeout or 30
  table.insert(cmd, '--max-time')
  table.insert(cmd, tostring(timeout))
  
  table.insert(cmd, '-X')
  table.insert(cmd, 'POST')
  table.insert(cmd, '-H')
  table.insert(cmd, 'Authorization: Bearer ' .. api_key)
  table.insert(cmd, '-H')
  table.insert(cmd, 'Content-Type: application/json')
  table.insert(cmd, '--data')
  table.insert(cmd, payload_json)
  table.insert(cmd, 'https://api.firecrawl.dev/v2/search')

  -- Execute curl (with security masking for error messages)
  local safe_cmd = {}
  for _, part in ipairs(cmd) do
    if part:match('^Authorization:') then
      table.insert(safe_cmd, 'Authorization: Bearer ***')
    else
      table.insert(safe_cmd, part)
    end
  end
  local safe_cmd_str = table.concat(safe_cmd, ' ')

  local result
  local exit_code

  if vim.system then
    local job = vim.system(cmd, {
      text = true,
      timeout = timeout * 1000,
    })
    local system_result = job:wait()
    result = system_result.stdout or system_result.stderr or ''
    exit_code = system_result.code
  else
    result = vim.fn.system(cmd)
    exit_code = vim.v.shell_error
  end

  if exit_code ~= 0 then
    return {
      error = string.format(
        'Firecrawl API request failed (exit code: %d):\nCommand: %s\nOutput: %s',
        exit_code,
        safe_cmd_str,
        result
      ),
    }
  end

  -- Parse response
  local ok, response = pcall(vim.json.decode, result)
  if not ok then
    return {
      error = 'Failed to parse Firecrawl API response as JSON:\n' .. result,
    }
  end

  if not response.success then
    return {
      error = 'Firecrawl API returned error: ' .. (response.error or 'unknown'),
    }
  end

  -- Format results
  local web_results = response.data and response.data.web or {}
  local lines = {}
  table.insert(lines, string.format('Firecrawl search results for "%s":', action.query))
  table.insert(lines, string.format('Found %d web results.', #web_results))
  table.insert(lines, '')

  for i, item in ipairs(web_results) do
    table.insert(lines, string.format('%d. %s', i, item.title or 'No title'))
    table.insert(lines, string.format('   URL: %s', item.url or 'No URL'))
    if item.description then
      table.insert(lines, string.format('   Description: %s', item.description))
    end
    if item.position then
      table.insert(lines, string.format('   Position: %d', item.position))
    end
    table.insert(lines, '')
  end

  -- Include other result types if present
  if response.data.images and #response.data.images > 0 then
    table.insert(lines, string.format('Images: %d results', #response.data.images))
  end
  if response.data.news and #response.data.news > 0 then
    table.insert(lines, string.format('News: %d results', #response.data.news))
  end

  local content = table.concat(lines, '\n')
  return {
    content = content,
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'web_search',
      description = [[
        Search the web using Firecrawl API.
        
        This tool performs web search using Firecrawl (https://firecrawl.dev) and returns
        results including titles, URLs, descriptions, and positions.
        
        Requires a Firecrawl API key. Set in config via:
        ```lua
        require('chat').setup({
          api_key = { firecrawl = 'fc-YOUR_API_KEY' }
        })
        ```
        Or provide directly as parameter.
        
        EXAMPLES:
        
        1. Basic search:
           @web_search query="firecrawl web scraping"
        
        2. With result limit:
           @web_search query="neovim plugins" limit=10
        
        3. With scrape options (scrape content of results):
           @web_search query="latest news" scrape_options={"formats":["markdown"]}
        
        4. With explicit API key:
           @web_search query="test" api_key="fc-YOUR_API_KEY"
        
        5. With custom timeout:
           @web_search query="slow site" timeout=60
        ]],
      parameters = {
        type = 'object',
        properties = {
          query = {
            type = 'string',
            description = 'Search query string',
          },
          limit = {
            type = 'integer',
            description = 'Number of results to return (default: 5)',
            minimum = 1,
            maximum = 50,
          },
          scrape_options = {
            type = 'object',
            description = 'Options for scraping result pages (see Firecrawl docs)',
          },
          api_key = {
            type = 'string',
            description = 'Firecrawl API key (optional if configured in config.api_key.firecrawl)',
          },
          timeout = {
            type = 'integer',
            description = 'Timeout in seconds (default: 30, minimum: 1, maximum: 300)',
            minimum = 1,
            maximum = 300,
          },
        },
        required = { 'query' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if ok then
    local info_parts = {
      string.format('web_search "%s"', arguments.query),
    }
    if arguments.limit then
      table.insert(info_parts, string.format('limit=%d', arguments.limit))
    end
    return table.concat(info_parts, ' ')
  else
    return 'web_search'
  end
end

return M


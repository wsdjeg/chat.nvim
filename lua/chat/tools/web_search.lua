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
---@field engine? string
---@field limit? integer
---@field scrape_options? table
---@field api_key? string
---@field cx? string  -- Google Custom Search engine ID
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

  -- Determine search engine
  local engine = action.engine or 'firecrawl'
  if engine ~= 'firecrawl' and engine ~= 'google' then
    return {
      error = 'Engine must be either "firecrawl" or "google".',
    }
  end

  -- Check if curl is available
  if not is_curl_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  -- Get API key and engine-specific parameters
  local api_key = action.api_key
  local cx = action.cx  -- Google Custom Search engine ID

  if not api_key or api_key == '' then
    -- Try to get from config based on engine
    if type(config.config.api_key) == 'table' then
      if engine == 'firecrawl' and config.config.api_key.firecrawl then
        api_key = config.config.api_key.firecrawl
      elseif engine == 'google' and config.config.api_key.google then
        api_key = config.config.api_key.google
        -- Try to get cx from config if not provided
        if not cx and config.config.api_key.google_cx then
          cx = config.config.api_key.google_cx
        end
      elseif type(config.config.api_key) == 'string' and config.config.api_key ~= '' then
        api_key = config.config.api_key
      end
    end
  end

  -- Validate engine-specific requirements
  if engine == 'firecrawl' then
    if not api_key or api_key == '' then
      return {
        error = 'Firecrawl API key is required. Please set it in config.api_key.firecrawl or provide as parameter.',
      }
    end
  elseif engine == 'google' then
    if not api_key or api_key == '' then
      return {
        error = 'Google API key is required. Please set it in config.api_key.google or provide as parameter.',
      }
    end
    if not cx or cx == '' then
      return {
        error = 'Google Custom Search engine ID (cx) is required. Please set it in config.api_key.google_cx or provide as cx parameter.',
      }
    end
  end

  -- Build request based on engine
  local cmd = { 'curl' }
  table.insert(cmd, '-s')
  table.insert(cmd, '-L')
  table.insert(cmd, '--compressed')
  
  -- Timeout
  local timeout = action.timeout or 30
  table.insert(cmd, '--max-time')
  table.insert(cmd, tostring(timeout))
  
  if engine == 'firecrawl' then
    -- Build Firecrawl request payload
    local payload = {
      query = action.query,
      limit = action.limit or 5,
    }
    if action.scrape_options then
      payload.scrape_options = action.scrape_options
    end

    local payload_json = vim.json.encode(payload)
    
    table.insert(cmd, '-X')
    table.insert(cmd, 'POST')
    table.insert(cmd, '-H')
    table.insert(cmd, 'Authorization: Bearer ' .. api_key)
    table.insert(cmd, '-H')
    table.insert(cmd, 'Content-Type: application/json')
    table.insert(cmd, '--data')
    table.insert(cmd, payload_json)
    table.insert(cmd, 'https://api.firecrawl.dev/v2/search')
  else -- google
    -- Build Google Custom Search request
    local limit = action.limit or 10
    if limit > 10 then
      limit = 10  -- Google API maximum for free tier
    end
    
    -- URL encode query
    local encoded_query = vim.fn.escape(action.query, 'url')
    
    local url = string.format(
      'https://www.googleapis.com/customsearch/v1?key=%s&cx=%s&q=%s&num=%d',
      api_key,
      cx,
      encoded_query,
      limit
    )
    
    table.insert(cmd, '-X')
    table.insert(cmd, 'GET')
    table.insert(cmd, url)
  end

  -- Execute curl (with security masking for error messages)
  local safe_cmd = {}
  for _, part in ipairs(cmd) do
    if part:match('^Authorization:') then
      table.insert(safe_cmd, 'Authorization: Bearer ***')
    elseif part:match('^key=') then
      table.insert(safe_cmd, 'key=***')
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
        '%s API request failed (exit code: %d):\nCommand: %s\nOutput: %s',
        engine == 'firecrawl' and 'Firecrawl' or 'Google',
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
      error = 'Failed to parse API response as JSON:\n' .. result,
    }
  end

  -- Format results based on engine
  local lines = {}
  
  if engine == 'firecrawl' then
    if not response.success then
      return {
        error = 'Firecrawl API returned error: ' .. (response.error or 'unknown'),
      }
    end

    local web_results = response.data and response.data.web or {}
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
  else -- google
    if response.error then
      return {
        error = 'Google API returned error: ' .. (response.error.message or 'unknown'),
      }
    end

    local items = response.items or {}
    table.insert(lines, string.format('Google search results for "%s":', action.query))
    table.insert(lines, string.format('Found %d results.', #items))
    if response.searchInformation then
      table.insert(lines, string.format('Search time: %s seconds', response.searchInformation.formattedSearchTime or 'unknown'))
      table.insert(lines, string.format('Total results: %s', response.searchInformation.formattedTotalResults or 'unknown'))
    end
    table.insert(lines, '')

    for i, item in ipairs(items) do
      table.insert(lines, string.format('%d. %s', i, item.title or 'No title'))
      table.insert(lines, string.format('   URL: %s', item.link or 'No URL'))
      if item.snippet then
        table.insert(lines, string.format('   Snippet: %s', item.snippet))
      end
      if item.displayLink then
        table.insert(lines, string.format('   Display link: %s', item.displayLink))
      end
      table.insert(lines, '')
    end
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
        Search the web using either Firecrawl or Google Custom Search API.
        
        Supports two search engines:
        1. Firecrawl (default): https://firecrawl.dev
        2. Google: Google Custom Search JSON API
        
        Requires appropriate API keys. Set in config via:
        ```lua
        require('chat').setup({
          api_key = { 
            firecrawl = 'fc-YOUR_API_KEY',
            google = 'YOUR_GOOGLE_API_KEY',
            google_cx = 'YOUR_SEARCH_ENGINE_ID'
          }
        })
        ```
        Or provide directly as parameters.
        
        EXAMPLES:
        
        1. Basic Firecrawl search:
           @web_search query="firecrawl web scraping"
        
        2. Firecrawl with result limit:
           @web_search query="neovim plugins" limit=10
        
        3. Google search:
           @web_search query="latest news" engine="google"
        
        4. Google search with custom API key and cx:
           @web_search query="test" engine="google" api_key="GOOGLE_API_KEY" cx="SEARCH_ENGINE_ID"
        
        5. Custom timeout:
           @web_search query="slow site" timeout=60
        
        6. Firecrawl with scrape options:
           @web_search query="news" scrape_options={"formats":["markdown"]}
        ]],
      parameters = {
        type = 'object',
        properties = {
          query = {
            type = 'string',
            description = 'Search query string',
          },
          engine = {
            type = 'string',
            description = 'Search engine to use: "firecrawl" or "google" (default: "firecrawl")',
            enum = { 'firecrawl', 'google' },
          },
          limit = {
            type = 'integer',
            description = 'Number of results to return (default: 5 for firecrawl, 10 for google)',
            minimum = 1,
            maximum = 50,
          },
          scrape_options = {
            type = 'object',
            description = 'Options for scraping result pages (Firecrawl only, see Firecrawl docs)',
          },
          api_key = {
            type = 'string',
            description = 'API key (optional if configured in config.api_key.firecrawl or config.api_key.google)',
          },
          cx = {
            type = 'string',
            description = 'Google Custom Search engine ID (required for Google engine if not in config.api_key.google_cx)',
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
    if arguments.engine then
      table.insert(info_parts, string.format('engine=%s', arguments.engine))
    end
    if arguments.limit then
      table.insert(info_parts, string.format('limit=%d', arguments.limit))
    end
    return table.concat(info_parts, ' ')
  else
    return 'web_search'
  end
end

return M

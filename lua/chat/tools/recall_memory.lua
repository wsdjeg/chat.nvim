local M = {}

local memory = require('chat.memory')
local sessions = require('chat.sessions')
local config = require('chat.config')

local function extract_keywords(text, max_keywords)
  if not text then
    return {}
  end

  local stop_words = {
    ['的'] = true,
    ['了'] = true,
    ['在'] = true,
    ['是'] = true,
    ['我'] = true,
    ['有'] = true,
    ['和'] = true,
    ['就'] = true,
    ['不'] = true,
    ['人'] = true,
    ['都'] = true,
    ['the'] = true,
    ['and'] = true,
    ['a'] = true,
    ['an'] = true,
    ['in'] = true,
    ['on'] = true,
    ['at'] = true,
    ['to'] = true,
    ['for'] = true,
    ['of'] = true,
    ['with'] = true,
  }

  local words = {}

  for word in text:gmatch('%w+') do
    word = word:lower()
    if #word > 1 and not stop_words[word] then
      words[word] = (words[word] or 0) + 1
    end
  end

  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte >= 0xE4 and byte <= 0xE9 then
      local char = text:sub(i, i + 2)
      if not stop_words[char] then
        words[char] = (words[char] or 0) + 1
      end
      i = i + 3
    else
      i = i + 1
    end
  end

  local sorted = {}
  for word, count in pairs(words) do
    table.insert(sorted, { word = word, count = count })
  end

  table.sort(sorted, function(a, b)
    return a.count > b.count
  end)

  local result = {}
  for j = 1, math.min(#sorted, max_keywords or 3) do
    table.insert(result, sorted[j].word)
  end

  return result
end

local function get_last_user_message(session_id)
  local messages = sessions.get_request_messages(session_id)
  for i = #messages, 1, -1 do
    if messages[i].role == 'user' then
      return messages[i].content
    end
  end
  return nil
end

local function parse_memory(mem_content)
  local category, content = mem_content:match('%[(%w+)%]%s*(.*)')
  return category or 'uncategorized', content or mem_content
end

local function format_time(timestamp)
  local diff = os.time() - timestamp
  if diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. ' minutes ago'
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. ' hours ago'
  elseif diff < 604800 then
    return math.floor(diff / 86400) .. ' days ago'
  else
    return os.date('%m-%d', timestamp)
  end
end

function M.recall_memory(arguments, ctx)
  if not config.config.memory or not config.config.memory.enable then
    return {
      error = 'Memory system is not enabled. Please configure chat.nvim memory.',
    }
  end

  local query = arguments.query
  if not query or query == '' then
    local last_msg = get_last_user_message(ctx.session)
    if last_msg then
      local keywords = extract_keywords(last_msg, 2)
      query = #keywords > 0 and table.concat(keywords, ' ')
        or last_msg:sub(1, 40)
    else
      return {
        content = 'Please provide a query, e.g.: @recall_memory query="vim config"',
      }
    end
  end

  local limit = math.min(arguments.limit or 5, 10)
  local target_session = ctx.session
  if arguments.all_sessions == true then
    target_session = nil
  end

  local memories = memory.retrieve_memories(query, target_session, limit)

  if #memories == 0 then
    local keywords = extract_keywords(query, 1)
    if #keywords > 0 then
      memories = memory.retrieve_memories(keywords[1], ctx.session, limit)
    end
  end

  if #memories == 0 then
    return {
      content = string.format(
        'No memories found related to "%s". Try adding new memories: @extract_memory',
        query
      ),
    }
  end

  local output =
    { string.format('**🔍 Found %d related memories:**\n', #memories) }

  for i, mem in ipairs(memories) do
    local category, content = parse_memory(mem.content)
    local time_str = format_time(mem.timestamp)

    local entry = string.format('%d. **[%s]** %s\n', i, category, content)
    entry = entry .. string.format('   🕒 %s | 💬 %s', time_str, mem.role)

    if mem.metadata and mem.metadata.cwd then
      local folder = mem.metadata.cwd:match('[^/\\]+$') or mem.metadata.cwd
      entry = entry .. string.format(' | 📁 %s', folder)
    end

    table.insert(output, entry)
    table.insert(output, '')
  end

  table.insert(
    output,
    '**💡 AI can reference these memories for responses.**'
  )

  return { content = table.concat(output, '\n') }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'recall_memory',
      description = [[
Retrieve relevant information from long-term memory and add to current conversation.
If no query is provided, automatically extracts keywords from current conversation.
Returns formatted memory list that AI can use for responses.

Parameters:
- query: Search query (optional, auto-extracted if not provided)
- limit: Number of results (default: 5, maximum: 10)

Examples:
@recall_memory query="vim configuration"
@recall_memory
      ]],
      parameters = {
        type = 'object',
        properties = {
          query = { type = 'string', description = 'Search query' },
          limit = {
            type = 'integer',
            description = 'Result count limit',
            default = 5,
            minimum = 1,
            maximum = 10,
          },
          all_sessions = {
            type = 'boolean',
            description = 'Search all sessions (default: false)',
            default = false,
          },
        },
      },
    },
  }
end

function M.info(arguments, ctx)
  return arguments.query and 'Recall: ' .. arguments.query:sub(1, 20)
    or 'Recall memories'
end

return M

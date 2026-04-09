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

-- 解析记忆内容（提取类型和分类）
local function parse_memory(mem_content)
  local memory_type, category, content =
    mem_content:match('%[(%w+)%]%[(%w+)%]%s*(.*)')

  if not memory_type then
    -- 尝试匹配旧格式 [category] content
    category, content = mem_content:match('%[(%w+)%]%s*(.*)')
    memory_type = 'long_term' -- 默认长期记忆
  end

  return {
    memory_type = memory_type or 'long_term',
    category = category or 'uncategorized',
    content = content or mem_content,
  }
end

-- 获取记忆类型图标
local function get_memory_type_icon(memory_type)
  local icons = {
    working = '⚡', -- 工作记忆（高优先级）
    daily = '📅', -- 日常记忆（临时）
    long_term = '💾', -- 长期记忆（永久）
  }
  return icons[memory_type] or '📝'
end

-- 获取分类图标
local function get_category_icon(category)
  local icons = {
    fact = '📊',
    preference = '❤️',
    skill = '🎯',
    event = '📌',
  }
  return icons[category] or '📄'
end

-- 获取优先级显示
local function get_priority_display(mem)
  local priority = mem.priority or 1.0

  if priority >= 2.0 then
    return '🔥 High Priority'
  elseif priority >= 1.5 then
    return '⭐ Medium Priority'
  else
    return '📌 Normal'
  end
end

local function format_time(timestamp)
  local diff = os.time() - timestamp
  if diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. ' min ago'
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
  local memory_type = arguments.memory_type -- 指定记忆类型
  local target_session = ctx.session
  if arguments.all_sessions == true then
    target_session = nil
  end

  -- 检索记忆
  local memories = memory.retrieve_memories(query, target_session, limit)

  -- 如果指定了记忆类型，过滤结果
  if memory_type then
    memories = vim.tbl_filter(function(mem)
      local parsed = parse_memory(mem.content)
      return parsed.memory_type == memory_type
    end, memories)
  end

  -- 如果没有结果，尝试用关键词重新搜索
  if #memories == 0 then
    local keywords = extract_keywords(query, 1)
    if #keywords > 0 then
      memories = memory.retrieve_memories(keywords[1], ctx.session, limit)

      if memory_type then
        memories = vim.tbl_filter(function(mem)
          local parsed = parse_memory(mem.content)
          return parsed.memory_type == memory_type
        end, memories)
      end
    end
  end

  if #memories == 0 then
    local type_hint = memory_type
        and string.format(' (type: %s)', memory_type)
      or ''
    return {
      content = string.format(
        'No memories found related to "%s"%s.\n\nTry:\n'
          .. '• @extract_memory text="your information"\n'
          .. '• @recall_memory query="different keywords"\n'
          .. '• @recall_memory memory_type="daily" query="%s"',
        query,
        type_hint,
        query
      ),
    }
  end

  -- 按记忆类型分组统计
  local type_stats = {
    working = 0,
    daily = 0,
    long_term = 0,
  }

  for _, mem in ipairs(memories) do
    local parsed = parse_memory(mem.content)
    type_stats[parsed.memory_type] = (type_stats[parsed.memory_type] or 0) + 1
  end

  -- 构建输出
  local output = {
    string.format('# 🔍 Found %d Related Memories\n', #memories),
  }

  -- 显示统计
  local stats_parts = {}
  if type_stats.working > 0 then
    table.insert(
      stats_parts,
      string.format('⚡ Working: %d', type_stats.working)
    )
  end
  if type_stats.daily > 0 then
    table.insert(
      stats_parts,
      string.format('📅 Daily: %d', type_stats.daily)
    )
  end
  if type_stats.long_term > 0 then
    table.insert(
      stats_parts,
      string.format('💾 Long-term: %d', type_stats.long_term)
    )
  end
  table.insert(
    output,
    '📊 **Statistics:** ' .. table.concat(stats_parts, ' | ') .. '\n'
  )

  -- 显示记忆详情
  for i, mem in ipairs(memories) do
    local parsed = parse_memory(mem.content)
    local time_str = format_time(mem.timestamp)

    local type_icon = get_memory_type_icon(parsed.memory_type)
    local category_icon = get_category_icon(parsed.category)
    local priority_display = get_priority_display(mem)

    local entry = string.format(
      '\n%d. %s **%s** %s **[%s]**\n',
      i,
      type_icon,
      parsed.memory_type,
      category_icon,
      parsed.category
    )
    entry = entry .. string.format('   > %s\n', parsed.content)
    entry = entry
      .. string.format('   🕒 %s | %s', time_str, priority_display)

    if mem.metadata and mem.metadata.cwd then
      local folder = mem.metadata.cwd:match('[^/\\]+$') or mem.metadata.cwd
      entry = entry .. string.format(' | 📁 %s', folder)
    end

    -- 工作记忆显示额外信息
    if parsed.memory_type == 'working' and mem.metadata then
      if mem.metadata.type then
        entry = entry .. string.format(' | 🏷️ %s', mem.metadata.type)
      end
      if mem.metadata.importance then
        entry = entry
          .. string.format(' | ⚠️ %s', mem.metadata.importance)
      end
    end

    table.insert(output, entry)
  end

  table.insert(output, '\n---')
  table.insert(
    output,
    '\n💡 **AI can reference these memories for better responses.**'
  )

  -- 提示操作
  table.insert(output, '\n\n🔧 **Actions:**')
  if type_stats.working > 0 then
    table.insert(
      output,
      '• Working memory will be cleaned after session ends'
    )
  end
  if type_stats.daily > 0 then
    table.insert(output, '• Daily memory expires in 7-30 days')
  end
  table.insert(
    output,
    '• Use `@recall_memory memory_type="long_term"` to filter by type'
  )

  return { content = table.concat(output, '\n') }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'recall_memory',
      description = [[
Retrieve relevant information from three-tier memory system.

MEMORY TYPES (Priority Order):
1. ⚡ Working Memory: Current session tasks/decisions (highest priority)
   - Auto-boosted priority × 2.0
   - Session lifetime
   - Task tracking, active context

2. 📅 Daily Memory: Temporary daily information (medium priority)
   - Auto-boosted priority × 1.5
   - Expires in 7-30 days
   - Daily tasks, reminders, schedules

3. 💾 Long-term Memory: Permanent knowledge (normal priority)
   - Standard retrieval
   - Never expires
   - Facts, preferences, skills

FEATURES:
• Auto keyword extraction from conversation
• Priority-based ranking
• Type filtering
• Session isolation

Examples:
@recall_memory query="vim configuration"
@recall_memory query="current task" memory_type="working"
@recall_memory query="today" memory_type="daily"
@recall_memory query="python" memory_type="long_term"
@recall_memory
      ]],
      parameters = {
        type = 'object',
        properties = {
          query = {
            type = 'string',
            description = 'Search query (auto-extracted if not provided)',
          },
          memory_type = {
            type = 'string',
            enum = { 'long_term', 'daily', 'working' },
            description = 'Filter by memory type (optional)',
          },
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

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if not ok then
    return 'Recall'
  end

  local parts = { 'Recall' }

  if arguments.query then
    table.insert(parts, string.format('"%s"', vim.fn.strcharpart(arguments.query, 0, 20)))
  end

  if arguments.memory_type then
    table.insert(parts, string.format('[%s]', arguments.memory_type))
  end

  return table.concat(parts, ' ')
end

return M

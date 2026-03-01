local M = {}

local memory = require('chat.memory')
local config = require('chat.config')

local CATEGORY_KEYWORDS = {
  fact = {
    '是', '有', '等于', '包括', '包含', '称为', '定义为', '事实', '实际上',
    'is', 'are', 'has', 'have', 'equals', 'includes', 'contains', 'means', 'defined as', 'fact', 'actually',
  },
  preference = {
    '喜欢', '讨厌', '偏好', '宁愿', '倾向于', '更爱', '最爱', '不喜欢',
    'like', 'dislike', 'prefer', 'love', 'hate', 'favorite', 'enjoy', 'disgust', "don't like",
  },
  skill = {
    '会', '能', '擅长', '知道如何', '掌握', '有能力', '精通', '熟练',
    'can', 'able to', 'good at', 'know how to', 'master', 'skill', 'capable', 'proficient', 'expert',
  },
  event = {
    '今天', '昨天', '明天', '上周', '下周', '发生', '事件', '完成', '参加了',
    'today', 'yesterday', 'tomorrow', 'last week', 'next week', 'happened', 'occurred', 'event', 'incident', 'finished',
  },
}

-- 记忆类型检测关键词
local MEMORY_TYPE_KEYWORDS = {
  working = {
    '当前', '正在', '现在', '这次', '这个问题', '我的任务', '当前任务', '这个bug', '正在处理',
    'current', 'now', 'working on', 'this task', 'this issue', 'in progress', 'active',
  },
  daily = {
    '今天', '明天', '本周', '下周', '今天要', '待办', '计划', '日程', '提醒', '每天',
    'today', 'tomorrow', 'this week', 'todo', 'task', 'schedule', 'reminder', 'daily', 'plan',
  },
}

local function utf8_char_count(str)
  if not str then return 0 end
  local count = 0
  for _ in str:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    count = count + 1
  end
  return count
end

local function has_chinese(text)
  for i = 1, #text do
    local byte = text:byte(i)
    if byte >= 0xE4 and byte <= 0xE9 then
      return true
    end
  end
  return false
end

-- 检测记忆分类
local function detect_category(text)
  local text_lower = text:lower()
  for category, keywords in pairs(CATEGORY_KEYWORDS) do
    for _, keyword in ipairs(keywords) do
      if text_lower:find(keyword:lower(), 1, true) then
        return category
      end
    end
  end
  return 'fact'
end

-- 智能检测记忆类型
local function detect_memory_type(text)
  local text_lower = text:lower()
  
  -- 优先检测工作记忆（当前任务）
  for _, keyword in ipairs(MEMORY_TYPE_KEYWORDS.working) do
    if text_lower:find(keyword:lower(), 1, true) then
      return 'working'
    end
  end
  
  -- 其次检测日常记忆（临时性）
  for _, keyword in ipairs(MEMORY_TYPE_KEYWORDS.daily) do
    if text_lower:find(keyword:lower(), 1, true) then
      return 'daily'
    end
  end
  
  -- 默认长期记忆（持久性）
  return 'long_term'
end

-- 检测工作记忆的子类型
local function detect_work_type(text)
  local text_lower = text:lower()
  
  local work_types = {
    task = {'任务', 'todo', 'task', '要做', '需要完成'},
    decision = {'决定', '选择', 'decision', '选择使用', '采用'},
    issue = {'问题', '错误', 'bug', 'issue', '错误', '失败'},
    context = {'上下文', '背景', 'context', '相关信息', '背景信息'},
  }
  
  for work_type, keywords in pairs(work_types) do
    for _, keyword in ipairs(keywords) do
      if text_lower:find(keyword:lower(), 1, true) then
        return work_type
      end
    end
  end
  
  return 'general'
end

-- 检测重要性
local function detect_importance(text)
  local text_lower = text:lower()
  
  local critical_keywords = {'紧急', '重要', 'critical', 'urgent', '必须', '关键'}
  for _, keyword in ipairs(critical_keywords) do
    if text_lower:find(keyword:lower(), 1, true) then
      return 'critical'
    end
  end
  
  local high_keywords = {'优先', '尽快', 'high', 'priority', '重要'}
  for _, keyword in ipairs(high_keywords) do
    if text_lower:find(keyword:lower(), 1, true) then
      return 'high'
    end
  end
  
  return 'normal'
end

local function extract_important_sentences(text, max_sentences)
  local sentences = {}
  local temp_fragments = {}

  for _, sentence in ipairs(vim.split(text, '[。！？.!?]\\zs', { trimempty = true })) do
    if #sentence > 0 then
      local char_count = utf8_char_count(sentence)
      if char_count >= 3 then
        local has_important_content = false

        if sentence:find('%d+') then
          has_important_content = true
        elseif sentence:find('[A-Z][a-z]+%s+[A-Z][a-z]+') then
          has_important_content = true
        elseif has_chinese(sentence) then
          has_important_content = true
        end

        local memory_keywords = { '重要', '记住', '关键', 'note', 'important', 'remember' }
        for _, kw in ipairs(memory_keywords) do
          if sentence:lower():find(kw:lower(), 1, true) then
            has_important_content = true
            break
          end
        end

        if has_important_content then
          table.insert(temp_fragments, {
            text = sentence,
            char_len = char_count,
            has_punctuation = sentence:match('[。！？.!?]$') ~= nil,
          })
        end
      end
    end
  end

  for i = #temp_fragments, 2, -1 do
    local prev = temp_fragments[i - 1]
    local curr = temp_fragments[i]
    if not prev.has_punctuation and curr.char_len <= 6 and (prev.char_len + curr.char_len) <= 50 then
      prev.text = prev.text .. curr.text
      prev.char_len = prev.char_len + curr.char_len
      prev.has_punctuation = curr.has_punctuation
      table.remove(temp_fragments, i)
    end
  end

  for _, frag in ipairs(temp_fragments) do
    local final_text = frag.text
    if not frag.has_punctuation and frag.char_len >= 6 then
      final_text = frag.text .. '。'
    end
    table.insert(sentences, final_text)
  end

  table.sort(sentences, function(a, b)
    local len_a = utf8_char_count(a)
    local len_b = utf8_char_count(b)
    local score_a = len_a >= 15 and len_a <= 100 and 2 or 1
    local score_b = len_b >= 15 and len_b <= 100 and 2 or 1
    if score_a == score_b then
      return len_a > len_b
    end
    return score_a > score_b
  end)

  return vim.list_slice(sentences, 1, max_sentences or 3)
end

function M.extract_memory(arguments, ctx)
  if not config.config.memory or not config.config.memory.enable then
    return { error = 'Memory system is not enabled. Please enable memory in chat.nvim configuration.' }
  end

  if not arguments.text and not arguments.memories then
    return { error = 'Either "text" or "memories" parameter is required.' }
  end

  local extracted_memories = {}

  if arguments.memories then
    -- 处理批量记忆
    local memories_data = arguments.memories
    if type(memories_data) == 'string' then
      local ok, parsed = pcall(vim.json.decode, memories_data)
      if not ok then
        return { error = 'Failed to parse memories JSON: ' .. tostring(parsed) }
      end
      memories_data = parsed
    end

    if not vim.islist(memories_data) then
      return { error = 'memories parameter must be an array.' }
    end

    for i, mem in ipairs(memories_data) do
      if type(mem) ~= 'table' or not mem.content then
        return { error = string.format('Memory at index %d is invalid (must contain "content" field).', i) }
      end

      local memory_type = mem.memory_type or arguments.memory_type or detect_memory_type(mem.content)
      local category = mem.category or detect_category(mem.content)
      
      -- 构建标记内容
      local marked_content = string.format('[%s][%s] %s', memory_type, category, mem.content)
      
      -- 准备metadata
      local metadata = nil
      if memory_type == 'working' then
        metadata = {
          type = mem.work_type or detect_work_type(mem.content),
          importance = mem.importance or detect_importance(mem.content),
        }
      end

      -- 存储到对应的记忆系统
      local memory_id = memory.store_memory(ctx.session, 'system', marked_content, memory_type)

      if memory_id then
        table.insert(extracted_memories, {
          id = memory_id,
          content = mem.content,
          memory_type = memory_type,
          category = category,
          stored = true,
        })
      end
    end

  elseif arguments.text then
    -- 处理文本提取
    if type(arguments.text) ~= 'string' then
      return { error = 'text parameter must be a string.' }
    end

    local sentences = extract_important_sentences(arguments.text, 5)
    for _, sentence in ipairs(sentences) do
      local memory_type = arguments.memory_type or detect_memory_type(sentence)
      local category = arguments.category or detect_category(sentence)
      
      -- 构建标记内容
      local marked_content = string.format('[%s][%s] %s', memory_type, category, sentence)
      
      -- 准备metadata（工作记忆专用）
      local metadata = nil
      if memory_type == 'working' then
        metadata = {
          type = detect_work_type(sentence),
          importance = detect_importance(sentence),
        }
      end

      -- 存储记忆
      local memory_id = memory.store_memory(ctx.session, 'system', marked_content, memory_type)

      if memory_id then
        table.insert(extracted_memories, {
          id = memory_id,
          content = sentence,
          memory_type = memory_type,
          category = category,
          metadata = metadata,
          stored = true,
        })
      end
    end
  end

  if #extracted_memories == 0 then
    return { content = 'No memorable information extracted. The text may not contain persistent/reusable content.' }
  end

  -- 统计各类型记忆数量
  local type_stats = {
    long_term = 0,
    daily = 0,
    working = 0,
  }
  for _, mem in ipairs(extracted_memories) do
    type_stats[mem.memory_type] = (type_stats[mem.memory_type] or 0) + 1
  end

  return {
    content = vim.json.encode({
      extracted_count = #extracted_memories,
      type_statistics = type_stats,
      memories = extracted_memories,
    }, { indent = 2 }),
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'extract_memory',
      description = [[
Extract memories from conversation text into three-tier memory system.

MEMORY TYPES:
• long_term: Permanent knowledge (facts, preferences, skills) - Never expires
• daily: Temporary daily information (tasks, reminders, schedules) - Expires in 7-30 days
• working: Current session focus (current task, context, decisions) - Session lifetime

AUTO-DETECTION:
System automatically detects memory type based on keywords:
- "当前/正在/current" → working memory (high priority)
- "今天/明天/todo/today" → daily memory (temporary)
- Other persistent info → long_term memory (permanent)

CATEGORIES:
• fact: Verifiable objective facts, data, definitions
• preference: Personal habits, preferences, routines
• skill: Technical abilities, knowledge, expertise
• event: Specific events, occurrences

Examples:
@extract_memory text="Python的GIL是全局解释器锁" memory_type="long_term"
@extract_memory text="今天要完成用户登录功能" memory_type="daily"
@extract_memory text="当前正在修复登录bug" memory_type="working"
@extract_memory text="我习惯用Vim写代码" category="preference"
@extract_memory memories='[{"content":"事实1","category":"fact"},{"content":"偏好1","category":"preference"}]'
      ]],
      parameters = {
        type = 'object',
        properties = {
          text = { type = 'string', description = 'Text to analyze (auto-extraction mode)' },
          memories = {
            type = 'array',
            description = 'Already extracted memories array',
            items = {
              type = 'object',
              properties = {
                content = { type = 'string', description = 'Memory content' },
                memory_type = { 
                  type = 'string', 
                  enum = { 'long_term', 'daily', 'working' }, 
                  description = 'Memory type (auto-detected if not specified)' 
                },
                category = { 
                  type = 'string', 
                  enum = { 'fact', 'preference', 'skill', 'event' }, 
                  description = 'Memory category (optional)' 
                },
                work_type = {
                  type = 'string',
                  enum = { 'general', 'task', 'decision', 'context', 'issue' },
                  description = 'Working memory subtype (only for working memory)'
                },
                importance = {
                  type = 'string',
                  enum = { 'low', 'normal', 'high', 'critical' },
                  description = 'Importance level (only for working memory)'
                },
              },
              required = { 'content' },
            },
          },
          memory_type = { 
            type = 'string', 
            enum = { 'long_term', 'daily', 'working' }, 
            description = 'Default memory type for all memories' 
          },
          category = { 
            type = 'string', 
            enum = { 'fact', 'preference', 'skill', 'event' }, 
            description = 'Default category for all memories' 
          },
        },
      },
    },
  }
end

function M.info(arguments, ctx)
  local parts = {}
  
  if arguments.text then
    table.insert(parts, string.format('Extract from: %.40s', arguments.text))
  elseif arguments.memories then
    local count = type(arguments.memories) == 'table' and #arguments.memories or 0
    table.insert(parts, string.format('Store %d memories', count))
  end
  
  if arguments.memory_type then
    table.insert(parts, string.format('→ %s', arguments.memory_type))
  end
  
  return #parts > 0 and table.concat(parts, ' ') or 'extract_memory'
end

return M

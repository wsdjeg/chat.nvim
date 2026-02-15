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

      local category = mem.category or detect_category(mem.content)
      local marked_content = string.format('[%s] %s', category, mem.content)
      local memory_id = memory.store_memory(ctx.session, 'system', marked_content)

      if memory_id then
        table.insert(extracted_memories, {
          id = memory_id,
          content = mem.content,
          category = category,
          stored = true,
        })
      end
    end

  elseif arguments.text then
    if type(arguments.text) ~= 'string' then
      return { error = 'text parameter must be a string.' }
    end

    local sentences = extract_important_sentences(arguments.text, 5)
    for _, sentence in ipairs(sentences) do
      local category = arguments.category or detect_category(sentence)
      local marked_content = string.format('[%s] %s', category, sentence)
      local memory_id = memory.store_memory(ctx.session, 'system', marked_content)

      if memory_id then
        table.insert(extracted_memories, {
          id = memory_id,
          content = sentence,
          category = category,
          stored = true,
        })
      end
    end
  end

  if #extracted_memories == 0 then
    return { content = 'No memorable information extracted. The text may not contain persistent/reusable content.' }
  end

  return {
    content = vim.json.encode({
      extracted_count = #extracted_memories,
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
Extract long-term memories from conversation text, focusing ONLY on factual information and habitual patterns.
Filter out subjective feelings, temporary states, and irrelevant chatter. Only extract persistent and reusable information.

PRIMARY CATEGORIES:
• fact: Verifiable objective facts, data, definitions, rules
• preference: Personal habits, routine behaviors, regular practices

OPTIONAL CATEGORIES:
• skill: Technical abilities and knowledge
• event: Specific events and occurrences

Examples:
@extract_memory text="Python的GIL是全局解释器锁，我习惯用Vim写代码" category="fact"
@extract_memory text="我每天早晨6点起床锻炼，通常下午3点喝咖啡" category="preference"
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
                category = { type = 'string', enum = { 'fact', 'preference', 'skill', 'event' }, description = 'Memory category (optional)' },
              },
              required = { 'content' },
            },
          },
          category = { type = 'string', enum = { 'fact', 'preference', 'skill', 'event' }, description = 'Suggested category' },
        },
      },
    },
  }
end

function M.info(arguments, ctx)
  if arguments.text then
    return string.format('Extract memories from text: %.50s', arguments.text)
  elseif arguments.memories then
    return string.format('Store %d memories', type(arguments.memories) == 'table' and #arguments.memories or 0)
  end
  return 'extract_memory'
end

return M

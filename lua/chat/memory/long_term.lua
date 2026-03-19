-- lua/chat/memory/long_term.lua
local M = {}
local config = require('chat.config')

local long_term_memories = {}

-- 生成记忆ID
local function generate_id()
  local MEMORY_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  return string.format(
    '%s-%s',
    os.date(MEMORY_ID_STRFTIME_FORMAT),
    math.random(1000, 9999)
  )
end

-- 获取存储路径
local function get_storage_path()
  return vim.fs.normalize(
    (
      config.config.memory.storage_dir
      or vim.fn.stdpath('cache') .. '/chat.nvim/memory/'
    ) .. '/long_term_memories.json'
  )
end

-- 初始化存储目录
local function init_storage()
  local storage_dir = config.config.memory.storage_dir
    or vim.fn.stdpath('cache') .. '/chat.nvim/memory/'

  if vim.fn.isdirectory(storage_dir) == 0 then
    vim.fn.mkdir(storage_dir, 'p')
  end
end

-- 文本相似度计算
function M.text_similarity(query, content)
  if not query or not content then
    return 0
  end

  local query_lower = query:lower()
  local content_lower = content:lower()

  -- 完全匹配
  if query_lower == content_lower then
    return 1.0
  end

  -- 子串匹配
  if content_lower:find(query_lower, 1, true) then
    return 0.8
  end

  -- 分词匹配
  local function split_words(text)
    local words = {}
    -- 英文单词
    for word in text:gmatch('%w+') do
      words[word:lower()] = true
    end
    -- 中文字符（简单的字符匹配）
    local i = 1
    while i <= #text do
      local byte = text:byte(i)
      if byte >= 0xE4 and byte <= 0xE9 then
        local gram = text:sub(i, i + 2)
        words[gram] = true
        i = i + 3
      else
        i = i + 1
      end
    end
    return words
  end

  local query_words = split_words(query_lower)
  local content_words = split_words(content_lower)

  local matches = 0
  local total = 0
  for word in pairs(query_words) do
    total = total + 1
    if content_words[word] then
      matches = matches + 1
    end
  end

  if total == 0 then
    return 0
  end

  return matches / total
end

-- 解析记忆内容（提取类型和分类）
local function parse_memory_metadata(content)
  local memory_type, category, text =
    content:match('%[(%w+)%]%[(%w+)%]%s*(.*)')

  if not memory_type then
    -- 尝试匹配旧格式 [category] content
    category, text = content:match('%[(%w+)%]%s*(.*)')
    memory_type = 'long_term'
  end

  return {
    memory_type = memory_type or 'long_term',
    category = category or 'fact',
    content = text or content,
  }
end

-- 存储长期记忆
function M.store(session, role, content, metadata)
  if not config.config.memory.long_term.enable then
    return nil
  end

  local memory = {
    id = generate_id(),
    session = session,
    role = role,
    content = content,
    timestamp = os.time(),
    access_count = 0,
    last_accessed = os.time(),
    metadata = metadata or {
      memory_type = 'long_term',
      category = 'fact',
      source = 'extracted',
      confidence = 1.0,
    },
  }

  -- 解析内容中的元数据标记
  local parsed = parse_memory_metadata(content)
  if parsed.memory_type then
    memory.metadata.memory_type = parsed.memory_type
    memory.metadata.category = parsed.category
  end

  table.insert(long_term_memories, memory)

  -- 限制最大记忆数量
  local max_memories = config.config.memory.long_term.max_memories or 500
  if #long_term_memories > max_memories then
    -- 按访问次数和时间排序，保留重要的记忆
    table.sort(long_term_memories, function(a, b)
      -- 优先保留高置信度和频繁访问的记忆
      local score_a = (a.access_count or 0) + (a.metadata.confidence or 0)
      local score_b = (b.access_count or 0) + (b.metadata.confidence or 0)
      return score_a > score_b
    end)
    long_term_memories = vim.list_slice(long_term_memories, 1, max_memories)
  end

  M.save()
  return memory.id
end

-- 检索长期记忆
function M.retrieve(query, session, limit)
  if not config.config.memory.long_term.enable then
    return {}
  end

  limit = limit or config.config.memory.long_term.retrieval_limit or 3
  local threshold = config.config.memory.long_term.similarity_threshold or 0.3
  local scored = {}

  for _, memory in ipairs(long_term_memories) do
    -- 会话过滤（可选）
    if not session or memory.session == session then
      local similarity = M.text_similarity(query, memory.content)

      -- 访问频率加成
      local access_bonus = math.min((memory.access_count or 0) * 0.05, 0.2)

      -- 置信度加成
      local confidence_bonus = (memory.metadata.confidence or 1.0) * 0.1

      -- 时间衰减（越久远的记忆权重略低）
      local age_days = (os.time() - memory.timestamp) / 86400
      local recency_bonus = math.max(0, (30 - age_days) / 30) * 0.1

      local total_score = similarity
        + access_bonus
        + confidence_bonus
        + recency_bonus

      if total_score >= threshold then
        table.insert(scored, {
          memory = memory,
          similarity = similarity,
          priority = total_score,
        })
      end
    end
  end

  -- 按优先级排序
  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)

  -- 返回结果并更新访问计数
  local results = {}
  for i = 1, math.min(#scored, limit) do
    local mem = scored[i].memory
    mem.access_count = (mem.access_count or 0) + 1
    mem.last_accessed = os.time()
    mem.priority = scored[i].priority
    table.insert(results, mem)
  end

  -- 异步保存访问计数更新
  vim.defer_fn(function()
    M.save()
  end, 1000)

  return results
end

-- 按分类检索
function M.retrieve_by_category(category, limit)
  limit = limit or 10

  local filtered = vim.tbl_filter(function(mem)
    return mem.metadata and mem.metadata.category == category
  end, long_term_memories)

  -- 按时间排序（最新的在前）
  table.sort(filtered, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return vim.list_slice(filtered, 1, limit)
end

-- 按关键词搜索
function M.search_by_keywords(keywords, limit)
  limit = limit or 10
  local scored = {}

  for _, memory in ipairs(long_term_memories) do
    local score = 0
    for _, keyword in ipairs(keywords) do
      if memory.content:lower():find(keyword:lower(), 1, true) then
        score = score + 1
      end
    end

    if score > 0 then
      table.insert(scored, {
        memory = memory,
        score = score,
      })
    end
  end

  table.sort(scored, function(a, b)
    return a.score > b.score
  end)

  return vim.tbl_map(function(item)
    return item.memory
  end, vim.list_slice(scored, 1, limit))
end

-- 获取所有记忆（用于统计和管理）
function M.get_all()
  return vim.tbl_map(function(m)
    return {
      id = m.id,
      content = m.content,
      session = m.session,
      timestamp = m.timestamp,
      access_count = m.access_count,
      category = m.metadata and m.metadata.category,
      confidence = m.metadata and m.metadata.confidence,
    }
  end, long_term_memories)
end

-- 删除记忆
function M.delete(id)
  local count_before = #long_term_memories
  long_term_memories = vim.tbl_filter(function(mem)
    return mem.id ~= id
  end, long_term_memories)

  if #long_term_memories < count_before then
    M.save()
    return true
  end
  return false
end

-- 批量删除（按条件）
function M.delete_by_filter(filter_fn)
  local count_before = #long_term_memories
  long_term_memories = vim.tbl_filter(function(mem)
    return not filter_fn(mem)
  end, long_term_memories)

  local removed = count_before - #long_term_memories
  if removed > 0 then
    M.save()
  end
  return removed
end

-- 更新记忆内容
function M.update(id, new_content, new_metadata)
  for _, mem in ipairs(long_term_memories) do
    if mem.id == id then
      mem.content = new_content
      if new_metadata then
        mem.metadata =
          vim.tbl_deep_extend('force', mem.metadata, new_metadata)
      end
      mem.timestamp = os.time()
      M.save()
      return true
    end
  end
  return false
end

-- 合并重复记忆
function M.merge_duplicates()
  local seen = {}
  local duplicates = {}

  -- 检测重复内容
  for i, mem in ipairs(long_term_memories) do
    local content_key = mem.content:lower():gsub('%s+', ' ')
    if seen[content_key] then
      table.insert(duplicates, i)
      -- 合并元数据到原始记忆
      local original = long_term_memories[seen[content_key]]
      original.access_count = (original.access_count or 0)
        + (mem.access_count or 0)
      original.metadata.confidence = math.max(
        original.metadata.confidence or 1.0,
        mem.metadata.confidence or 1.0
      )
    else
      seen[content_key] = i
    end
  end

  -- 移除重复记忆（从后往前删除）
  table.sort(duplicates, function(a, b)
    return a > b
  end)
  for _, idx in ipairs(duplicates) do
    table.remove(long_term_memories, idx)
  end

  if #duplicates > 0 then
    M.save()
  end

  return #duplicates
end

-- 清理过期或低质量记忆
function M.cleanup()
  local count_before = #long_term_memories

  -- 移除低置信度且从未访问的记忆
  long_term_memories = vim.tbl_filter(function(mem)
    local confidence = mem.metadata and mem.metadata.confidence or 1.0
    local access_count = mem.access_count or 0

    -- 保留：置信度 > 0.5 或至少被访问过一次
    return confidence > 0.5 or access_count > 0
  end, long_term_memories)

  local removed = count_before - #long_term_memories
  if removed > 0 then
    M.save()
  end

  return removed
end

-- 获取统计信息
function M.get_stats()
  local stats = {
    total = #long_term_memories,
    by_category = {},
    by_session = {},
    avg_access_count = 0,
    avg_age_days = 0,
  }

  local total_access = 0
  local total_age = 0

  for _, mem in ipairs(long_term_memories) do
    -- 按分类统计
    local category = mem.metadata and mem.metadata.category or 'uncategorized'
    stats.by_category[category] = (stats.by_category[category] or 0) + 1

    -- 按会话统计
    local session = mem.session or 'unknown'
    stats.by_session[session] = (stats.by_session[session] or 0) + 1

    -- 访问统计
    total_access = total_access + (mem.access_count or 0)

    -- 年龄统计
    total_age = total_age + (os.time() - mem.timestamp)
  end

  if #long_term_memories > 0 then
    stats.avg_access_count = total_access / #long_term_memories
    stats.avg_age_days = (total_age / #long_term_memories) / 86400
  end

  return stats
end

-- 导出记忆（用于备份或迁移）
function M.export(format)
  format = format or 'json'

  if format == 'json' then
    return vim.json.encode(long_term_memories, { indent = 2 })
  elseif format == 'markdown' then
    local lines = { '# Long-term Memories\n' }
    local stats = M.get_stats() -- 获取统计信息

    for category, _ in pairs(stats.by_category) do
      table.insert(lines, string.format('\n## %s\n', category))
      for _, mem in ipairs(M.retrieve_by_category(category, 100)) do
        table.insert(lines, string.format('- %s\n', mem.content))
      end
    end

    return table.concat(lines, '\n')
  end

  return nil
end

-- 导入记忆
function M.import(data, format)
  format = format or 'json'

  if format == 'json' then
    local ok, memories = pcall(vim.json.decode, data)
    if ok and type(memories) == 'table' then
      for _, mem in ipairs(memories) do
        -- 重新生成ID以避免冲突
        mem.id = generate_id()
        mem.imported = true
        mem.imported_at = os.time()
        table.insert(long_term_memories, mem)
      end
      M.save()
      return #memories
    end
  end

  return 0
end

-- 加载记忆
function M.load()
  init_storage()

  local path = get_storage_path()
  local file = io.open(path, 'r')

  if not file then
    long_term_memories = {}
    return long_term_memories
  end

  local content = file:read('*a')
  io.close(file)

  local ok, parsed = pcall(vim.json.decode, content)
  if ok and type(parsed) == 'table' then
    long_term_memories = parsed
  else
    long_term_memories = {}
  end

  return long_term_memories
end

-- 保存记忆
function M.save()
  init_storage()

  local path = get_storage_path()
  local file = io.open(path, 'w')

  if file then
    file:write(vim.json.encode(long_term_memories))
    io.close(file)
  end
end

-- 批量操作接口
function M.batch_store(memories_data)
  local ids = {}
  for _, mem_data in ipairs(memories_data) do
    local id = M.store(
      mem_data.session,
      mem_data.role,
      mem_data.content,
      mem_data.metadata
    )
    if id then
      table.insert(ids, id)
    end
  end
  return ids
end

-- 高级搜索（支持组合条件）
function M.advanced_search(options)
  options = options or {}
  local results = {}

  for _, mem in ipairs(long_term_memories) do
    local match = true

    -- 分类过滤
    if options.category and mem.metadata.category ~= options.category then
      match = false
    end

    -- 会话过滤
    if options.session and mem.session ~= options.session then
      match = false
    end

    -- 时间范围过滤
    if options.since and mem.timestamp < options.since then
      match = false
    end

    if options['until'] and mem.timestamp > options['until'] then
      match = false
    end

    -- 置信度过滤
    if
      options.min_confidence
      and (mem.metadata.confidence or 0) < options.min_confidence
    then
      match = false
    end

    -- 文本搜索
    if options.query then
      local similarity = M.text_similarity(options.query, mem.content)
      if similarity < (options.threshold or 0.3) then
        match = false
      end
      mem.search_score = similarity
    end

    if match then
      table.insert(results, mem)
    end
  end

  -- 排序
  if options.sort_by then
    table.sort(results, function(a, b)
      if options.sort_by == 'timestamp' then
        return a.timestamp > b.timestamp
      elseif options.sort_by == 'access_count' then
        return (a.access_count or 0) > (b.access_count or 0)
      elseif options.sort_by == 'relevance' then
        return (a.search_score or 0) > (b.search_score or 0)
      end
      return false
    end)
  end

  -- 限制结果数量
  if options.limit then
    results = vim.list_slice(results, 1, options.limit)
  end

  return results
end

-- 初始化
M.load()

-- 定期清理（每周清理一次低质量记忆）
vim.loop.new_timer():start(604800000, 604800000, function()
  vim.schedule(function()
    M.cleanup()
    M.merge_duplicates()
  end)
end)

return M

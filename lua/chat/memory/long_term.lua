-- lua/chat/memory/long_term.lua
local M = {}

local config = require('chat.config')
local similarity = require('chat.memory.similarity')
local persist = require('chat.memory.persist')

local long_term_memories = {}

-- 90 天未被检索视为陈旧，可被 cleanup 淘汰
local STALE_SECONDS = 90 * 86400

-- 去重阈值：相似度 >= 0.85 视为同一条记忆
local DEDUP_THRESHOLD = 0.85

-- 定时维护间隔（每周清理一次陈旧记忆 + 合并重复）
local MAINTENANCE_INTERVAL_MS = 604800000

-- 持久化管道：延迟加载 + 可关闭定时器（见 chat.memory.persist）
local db = persist.new({
  name = 'LongTerm',
  path = function()
    local dir = config.get_memory_storage_dir()
    if not dir then
      return nil
    end
    return dir .. '/long_term_memories.json'
  end,
  get = function()
    return long_term_memories
  end,
  set = function(list)
    long_term_memories = list
  end,
})

---确保当前配置对应的数据已加载（目录变化时重读），并保证维护定时器在运行。
---模块不再在 require 时启动定时器（那时配置还没就绪），所以首次使用要补上，
---否则懒加载路径下周期性 cleanup/merge 永远不会触发。
local function ready()
  db.ensure_loaded()
  db.start_timer(MAINTENANCE_INTERVAL_MS, function()
    M.cleanup()
    M.merge_duplicates()
  end)
end

-- 生成记忆ID
local function generate_id()
  local MEMORY_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  return string.format(
    '%s-%s',
    os.date(MEMORY_ID_STRFTIME_FORMAT),
    math.random(1000, 9999)
  )
end

-- 读取置信度（nil 安全：import / 手工编辑的数据可能没有 metadata）
local function get_confidence(mem)
  return mem.metadata and mem.metadata.confidence or 1.0
end

-- 读取分类（nil 安全）
local function get_category(mem)
  return mem.metadata and mem.metadata.category
end

-- 把存储对象转成检索视图。
-- 检索不应把 priority / similarity 写回持久化记录，否则任何一次 save
-- 都会把检索态落盘。metadata 用引用共享，拷贝开销可忽略。
local function to_view(mem, priority)
  return {
    id = mem.id,
    session = mem.session,
    role = mem.role,
    content = mem.content,
    timestamp = mem.timestamp,
    metadata = mem.metadata,
    priority = priority,
  }
end

-- 文本相似度计算（委托给公共模块）
function M.text_similarity(query, content)
  return similarity.text_similarity(query, content)
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

  ready()

  -- 去重检查：相似度 >= 0.85 则更新已有记忆
  for _, existing in ipairs(long_term_memories) do
    if existing.session == session then
      local sim = similarity.text_similarity(content, existing.content)
      if sim >= DEDUP_THRESHOLD then
        -- 更新已有记忆
        existing.content = content
        existing.timestamp = os.time()
        existing.hit_count = (existing.hit_count or 0) + 1
        existing.updated_at = os.time()
        existing.last_accessed = os.time()
        M.save()
        return existing.id
      end
    end
  end

  local memory = {
    id = generate_id(),
    session = session,
    role = role,
    content = content,
    timestamp = os.time(),
    access_count = 0,
    hit_count = 1,
    last_accessed = os.time(),
    updated_at = os.time(),
    -- 合并默认值：调用方传入部分字段时，其余字段仍可用
    metadata = vim.tbl_deep_extend('force', {
      memory_type = 'long_term',
      category = 'fact',
      source = 'extracted',
      confidence = 1.0,
    }, metadata or {}),
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
    -- 按访问次数和置信度排序，保留重要的记忆
    table.sort(long_term_memories, function(a, b)
      local score_a = (a.access_count or 0) + get_confidence(a)
      local score_b = (b.access_count or 0) + get_confidence(b)
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

  ready()

  limit = limit or config.config.memory.long_term.retrieval_limit or 3
  local threshold = config.config.memory.long_term.similarity_threshold or 0.3
  local scored = {}

  for _, memory in ipairs(long_term_memories) do
    -- 会话过滤（可选）
    if not session or memory.session == session then
      local sim = similarity.text_similarity(query, memory.content)

      -- 访问频率加成
      local access_bonus = math.min((memory.access_count or 0) * 0.05, 0.2)

      -- 置信度加成（nil 安全）
      local confidence_bonus = get_confidence(memory) * 0.1

      -- 时间衰减（越久远的记忆权重略低）
      local age_days = (os.time() - memory.timestamp) / 86400
      local recency_bonus = math.max(0, (30 - age_days) / 30) * 0.1

      local total_score = sim + access_bonus + confidence_bonus + recency_bonus

      if total_score >= threshold then
        table.insert(scored, {
          memory = memory,
          similarity = sim,
          priority = total_score,
        })
      end
    end
  end

  -- 按优先级排序
  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)

  -- 只有入选的结果才算一次访问；同步保存，避免退出丢计数
  local results = {}
  local accessed = false
  for i = 1, math.min(#scored, limit) do
    local mem = scored[i].memory
    mem.access_count = (mem.access_count or 0) + 1
    mem.last_accessed = os.time()
    accessed = true
    table.insert(results, to_view(mem, scored[i].priority))
  end

  if accessed then
    M.save()
  end

  return results
end

-- 按分类检索
function M.retrieve_by_category(category, limit)
  ready()

  limit = limit or 10

  local filtered = vim.tbl_filter(function(mem)
    return get_category(mem) == category
  end, long_term_memories)

  -- 按时间排序（最新的在前）
  table.sort(filtered, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return vim.list_slice(filtered, 1, limit)
end

-- 按关键词搜索
function M.search_by_keywords(keywords, limit)
  ready()

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
  ready()

  return vim.tbl_map(function(m)
    return {
      id = m.id,
      content = m.content,
      session = m.session,
      timestamp = m.timestamp,
      access_count = m.access_count,
      hit_count = m.hit_count,
      updated_at = m.updated_at,
      category = get_category(m),
      confidence = m.metadata and m.metadata.confidence,
    }
  end, long_term_memories)
end

-- 删除记忆
function M.delete(id)
  ready()

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
  ready()

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
  ready()

  for _, mem in ipairs(long_term_memories) do
    if mem.id == id then
      mem.content = new_content
      if new_metadata then
        mem.metadata =
          vim.tbl_deep_extend('force', mem.metadata or {}, new_metadata)
      end
      mem.timestamp = os.time()
      M.save()
      return true
    end
  end
  return false
end

-- 合并重复记忆
--
-- 之前只比较 `content:lower():gsub('%s+',' ')` 的完全相等，与 store()
-- 使用的 0.85 相似度阈值不一致：近似重复（多一个空格、措辞微调）永远不会
-- 被合并，文件会慢慢长到 max_memories 上限。这里复用同一个 similarity，
-- 所以「会被 store() 去重的两条内容」在离线合并时也一定会被合并。
--
-- 合并只在**同一会话内**进行：跨会话合并会把 A 会话的记忆并进 B 会话的
-- 记录里，破坏 retrieve() 的会话隔离。
function M.merge_duplicates()
  ready()

  local kept = {}
  local merged_count = 0

  for _, mem in ipairs(long_term_memories) do
    local target = nil

    for _, candidate in ipairs(kept) do
      if
        candidate.session == mem.session
        and similarity.text_similarity(candidate.content, mem.content)
          >= DEDUP_THRESHOLD
      then
        target = candidate
        break
      end
    end

    if target then
      -- 合并元数据到原始记忆（import 进来的记忆可能没有 metadata）
      target.metadata = target.metadata or {}
      target.access_count = (target.access_count or 0)
        + (mem.access_count or 0)
      target.hit_count = (target.hit_count or 0) + (mem.hit_count or 0)
      target.metadata.confidence = math.max(
        target.metadata.confidence or 1.0,
        mem.metadata and mem.metadata.confidence or 1.0
      )
      -- 保留更新的时间戳，避免合并后看起来像陈旧记忆被 cleanup 掉
      if (mem.timestamp or 0) > (target.timestamp or 0) then
        target.timestamp = mem.timestamp
      end
      merged_count = merged_count + 1
    else
      table.insert(kept, mem)
    end
  end

  if merged_count > 0 then
    long_term_memories = kept
    M.save()
  end

  return merged_count
end

-- 清理陈旧记忆（长期零访问 + 超过 STALE_SECONDS 未更新）
-- 注意：存入时 confidence 恒为 1.0，基于置信度的条件永远为真，是空操作。
function M.cleanup()
  ready()

  local count_before = #long_term_memories
  local now = os.time()

  long_term_memories = vim.tbl_filter(function(mem)
    local access_count = mem.access_count or 0
    local age = now - (mem.timestamp or 0)

    -- 保留：被检索过，或仍在新鲜期内
    return access_count > 0 or age < STALE_SECONDS
  end, long_term_memories)

  local removed = count_before - #long_term_memories
  if removed > 0 then
    M.save()
  end

  return removed
end

-- 获取统计信息
function M.get_stats()
  ready()

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
    local category = get_category(mem) or 'uncategorized'
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
  ready()

  format = format or 'json'

  if format == 'json' then
    -- `indent` must be a string: a number is concatenated verbatim as the
    -- indent prefix and produces invalid JSON ("2\"key\""). A broken export
    -- could not be re-imported, which defeats the backup purpose.
    return vim.json.encode(long_term_memories, { indent = '  ' })
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
  ready()

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
--
-- 显式 load() 仍然可用（测试与手动重载），但模块不再在 require 时读盘：
-- 那一刻 config 还没 setup，读到的会是默认目录。首次使用时由 ready() 懒加载。
function M.load()
  db.start_timer(MAINTENANCE_INTERVAL_MS, function()
    M.cleanup()
    M.merge_duplicates()
  end)
  return db.load()
end

-- 保存记忆（原子写入，rename 失败时回退直接写，见 chat.memory.atomic）
function M.save()
  return db.save()
end

---维护定时器是否在运行
---@return boolean
function M.has_cleanup_timer()
  return db.has_timer()
end

---关闭维护定时器（句柄不再被丢弃，可随时停止）
function M.stop_cleanup_timer()
  db.stop_timer()
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
  ready()

  options = options or {}
  local matches = {}

  for _, mem in ipairs(long_term_memories) do
    local match = true

    -- 分类过滤（nil 安全）
    if options.category and get_category(mem) ~= options.category then
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
      and (mem.metadata and mem.metadata.confidence or 0)
        < options.min_confidence
    then
      match = false
    end

    -- 文本搜索（分数只存在本次查询的包装表里，不写回记忆）
    local score = nil
    if options.query then
      score = similarity.text_similarity(options.query, mem.content)
      if score < (options.threshold or 0.3) then
        match = false
      end
    end

    if match then
      table.insert(matches, { memory = mem, score = score })
    end
  end

  -- 排序
  if options.sort_by then
    table.sort(matches, function(a, b)
      if options.sort_by == 'timestamp' then
        return a.memory.timestamp > b.memory.timestamp
      elseif options.sort_by == 'access_count' then
        return (a.memory.access_count or 0) > (b.memory.access_count or 0)
      elseif options.sort_by == 'relevance' then
        return (a.score or 0) > (b.score or 0)
      end
      return false
    end)
  end

  -- 限制结果数量
  if options.limit then
    matches = vim.list_slice(matches, 1, options.limit)
  end

  return vim.tbl_map(function(item)
    return item.memory
  end, matches)
end

return M


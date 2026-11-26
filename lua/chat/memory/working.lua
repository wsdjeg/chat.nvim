local M = {}

local config = require('chat.config')
local similarity = require('chat.memory.similarity')
local persist = require('chat.memory.persist')

local working_memories = {}

-- 定时清理间隔（每 5 分钟）
local CLEANUP_INTERVAL_MS = 300000

-- Generate working memory ID
local function generate_id()
  return string.format('work-%s-%s', os.date('%H%M%S'), math.random(100, 999))
end

local function get_current_session()
  return require('chat.windows').current_session()
end

-- 持久化管道：延迟加载 + 可关闭定时器（见 chat.memory.persist）
local db = persist.new({
  name = 'Working',
  path = function()
    local dir = config.get_memory_storage_dir()
    if not dir then
      return nil
    end
    -- storage_dir 未必带尾斜杠（memory.storage_dir 可被用户改写）
    if dir:sub(-1) ~= '/' then
      dir = dir .. '/'
    end
    return dir .. 'working_memories.json'
  end,
  get = function()
    return working_memories
  end,
  set = function(list)
    working_memories = list
  end,
  on_loaded = function()
    -- 加载后立刻清掉 TTL 过期的记忆（内部会自行 ensure_loaded，
    -- 此时 loaded_path 已一致，不会递归重读）
    M.cleanup_expired()
  end,
})

---确保当前配置对应的数据已加载（目录变化时重读），并保证清理定时器在运行。
---模块不再在 require 时启动定时器（那时配置还没就绪），所以首次使用要补上。
local function ready()
  db.ensure_loaded()
  db.start_timer(CLEANUP_INTERVAL_MS, function()
    M.cleanup_expired()
  end)
end

-- 把存储对象转成检索视图：检索不应把 priority 写回持久化记录，
-- 否则任何一次 save 都会把检索态落盘。
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

function M.get_all()
  ready()

  return vim.tbl_filter(function(mem)
    return not mem.expired
  end, working_memories)
end

-- Store working memory
function M.store(session, role, content, metadata)
  if not config.config.memory.working.enable then
    return nil
  end

  ready()

  -- Use current session if not specified
  session = session or get_current_session()

  -- 去重检查：相似度 >= 0.85 则更新已有记忆
  local DEDUP_THRESHOLD = 0.85
  for _, existing in ipairs(working_memories) do
    if existing.session == session and not existing.expired then
      local sim = similarity.text_similarity(content, existing.content)
      if sim >= DEDUP_THRESHOLD then
        existing.content = content
        existing.timestamp = os.time()
        existing.hit_count = (existing.hit_count or 0) + 1
        existing.updated_at = os.time()
        -- 去重命中时也吸收新传入的 metadata（importance / type 变更生效）
        if metadata then
          existing.metadata = vim.tbl_deep_extend(
            'force',
            existing.metadata or {},
            metadata
          )
        end
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
    priority = 1.0, -- Base priority
    metadata = vim.tbl_deep_extend('force', {
      type = 'general', -- general, task, decision, context, issue
      importance = 'normal', -- low, normal, high, critical
    }, metadata or {}),
    ttl = 3600, -- Default 1 hour TTL (time-to-live)
    created_at = os.time(),
    hit_count = 1,
    updated_at = os.time(),
  }

  table.insert(working_memories, memory)

  -- Limit the number of working memories
  local max_memories = config.config.memory.working.max_memories or 20
  if #working_memories > max_memories then
    -- Remove oldest and lowest priority memories
    table.sort(working_memories, function(a, b)
      if a.priority ~= b.priority then
        return a.priority > b.priority
      end
      return a.timestamp > b.timestamp
    end)
    working_memories = vim.list_slice(working_memories, 1, max_memories)
  end

  M.save()
  return memory.id
end

-- Retrieve working memories
function M.retrieve(query, limit)
  if not config.config.memory.working.enable then
    return {}
  end

  ready()

  limit = limit or 10
  local session = get_current_session()
  local weight = config.config.memory.working.priority_weight or 2.0
  local scored = {}
  local now = os.time()

  for _, memory in ipairs(working_memories) do
    -- Check if expired
    if now - (memory.created_at or now) > (memory.ttl or 3600) then
      -- Mark as expired, cleanup later
      memory.expired = true
      goto continue
    end

    -- Calculate similarity
    local sim = similarity.text_similarity(query, memory.content)

    -- Session relevance bonus
    local session_bonus = 0
    if memory.session == session then
      session_bonus = 0.3
    end

    -- Importance bonus
    local importance_bonus = 0
    if memory.metadata then
      local importance_weights = {
        critical = 0.5,
        high = 0.3,
        normal = 0.1,
        low = 0,
      }
      importance_bonus = importance_weights[memory.metadata.importance] or 0
    end

    -- Time decay (newer is more important)
    local age_minutes = (now - (memory.timestamp or now)) / 60
    local recency_bonus = math.max(0, (60 - age_minutes) / 60) * 0.2

    -- Total priority (weight applied here, once -- chat.memory.init
    -- deliberately does not multiply again)
    local total_priority =
      (sim + session_bonus + importance_bonus + recency_bonus) * weight

    if total_priority > 0 then
      table.insert(scored, {
        memory = memory,
        priority = total_priority,
      })
    end

    ::continue::
  end

  -- Sort by priority
  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)

  -- Return results as views (never mutate the stored object)
  local results = {}
  for i = 1, math.min(#scored, limit) do
    table.insert(results, to_view(scored[i].memory, scored[i].priority))
  end

  return results
end

-- Get all working memories for specified session
function M.get_session_memories(session)
  ready()

  session = session or get_current_session()

  return vim.tbl_filter(function(mem)
    return mem.session == session and not mem.expired
  end, working_memories)
end

-- Cleanup expired memories
function M.cleanup_expired()
  ready()

  local now = os.time()
  local count_before = #working_memories

  working_memories = vim.tbl_filter(function(mem)
    return (now - (mem.created_at or now)) <= (mem.ttl or 3600)
  end, working_memories)

  local removed = count_before - #working_memories
  if removed > 0 then
    M.save()
  end

  return removed
end

-- Cleanup working memories for specified session
function M.cleanup_session(session)
  ready()

  session = session or get_current_session()

  local count_before = #working_memories
  working_memories = vim.tbl_filter(function(mem)
    return mem.session ~= session
  end, working_memories)

  local removed = count_before - #working_memories
  if removed > 0 then
    M.save()
  end

  return removed
end

-- Update memory importance
function M.update_importance(memory_id, importance)
  ready()

  for _, mem in ipairs(working_memories) do
    if mem.id == memory_id then
      mem.metadata = mem.metadata or {}
      mem.metadata.importance = importance
      M.save()
      return true
    end
  end
  return false
end

-- Extend memory TTL
function M.extend_ttl(memory_id, additional_seconds)
  ready()

  for _, mem in ipairs(working_memories) do
    if mem.id == memory_id then
      mem.ttl = mem.ttl + (additional_seconds or 3600)
      mem.timestamp = os.time() -- Refresh timestamp
      M.save()
      return true
    end
  end
  return false
end

-- Mark task as completed
function M.mark_completed(memory_id, notes)
  ready()

  for _, mem in ipairs(working_memories) do
    if mem.id == memory_id then
      mem.metadata = mem.metadata or {}
      mem.metadata.completed = true
      mem.metadata.completed_at = os.time()
      mem.metadata.notes = notes or mem.metadata.notes
      mem.metadata.importance = 'low' -- Lower priority for completed tasks
      M.save()
      return true
    end
  end
  return false
end

-- Get statistics
function M.get_stats(session)
  ready()

  session = session or get_current_session()

  local stats = {
    total = 0,
    by_type = {},
    by_importance = {},
    by_session = 0,
    expired = 0,
  }

  for _, mem in ipairs(working_memories) do
    if not mem.expired then
      stats.total = stats.total + 1

      -- Statistics by type
      local mem_type = mem.metadata and mem.metadata.type or 'general'
      stats.by_type[mem_type] = (stats.by_type[mem_type] or 0) + 1

      -- Statistics by importance
      local importance = mem.metadata and mem.metadata.importance or 'normal'
      stats.by_importance[importance] = (stats.by_importance[importance] or 0)
        + 1

      -- Current session statistics
      if mem.session == session then
        stats.by_session = stats.by_session + 1
      end
    else
      stats.expired = stats.expired + 1
    end
  end

  return stats
end

-- Text similarity (delegated to shared module, kept for backward compat)
function M.text_similarity(query, content)
  return similarity.text_similarity(query, content)
end

-- 加载/保存
--
-- 显式 load() 仍然可用，但模块不再在 require 时读盘：那一刻 config
-- 还没 setup，读到的会是默认目录。首次使用时由 ready() 懒加载。
function M.load()
  db.start_timer(CLEANUP_INTERVAL_MS, function()
    M.cleanup_expired()
  end)
  return db.load()
end

function M.save()
  return db.save()
end

---清理定时器是否在运行
---@return boolean
function M.has_cleanup_timer()
  return db.has_timer()
end

---关闭清理定时器（句柄不再被丢弃，可随时停止）
function M.stop_cleanup_timer()
  db.stop_timer()
end

-- Delete specified memory
function M.delete(memory_id)
  ready()

  local count_before = #working_memories
  working_memories = vim.tbl_filter(function(mem)
    return mem.id ~= memory_id
  end, working_memories)

  if #working_memories < count_before then
    M.save()
    return true
  end
  return false
end

-- Clear all working memories
function M.clear()
  ready()

  working_memories = {}
  M.save()
end

-- Promote working memory to long-term memory
function M.promote_to_long_term(memory_id)
  ready()

  local memory = nil
  for _, mem in ipairs(working_memories) do
    if mem.id == memory_id then
      memory = mem
      break
    end
  end

  if not memory then
    return nil, 'Memory not found'
  end

  -- Call long-term memory module to store
  local long_term = require('chat.memory.long_term')
  local long_term_id =
    long_term.store(memory.session, memory.role, memory.content)

  if long_term_id then
    -- Mark as promoted
    memory.metadata = memory.metadata or {}
    memory.metadata.promoted = true
    memory.metadata.promoted_to = long_term_id
    M.save()
    return long_term_id
  end

  return nil, 'Failed to promote to long-term memory'
end

return M


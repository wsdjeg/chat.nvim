-- lua/chat/memory/daily.lua
local M = {}
local config = require('chat.config')
local similarity = require('chat.memory.similarity')

local daily_memories = {}

-- 获取当天日期键
local function get_date_key(timestamp)
  return os.date('%Y-%m-%d', timestamp or os.time())
end

-- 存储日常记忆
function M.store(session, role, content)
  if not config.config.memory.daily.enable then
    return nil
  end
  local timestamp = os.time()

  -- 去重检查：相似度 >0.85 则更新已有记忆
  local DEDUP_THRESHOLD = 0.85
  for _, existing in ipairs(daily_memories) do
    if existing.session == session then
      local sim = similarity.text_similarity(content, existing.content)
      if sim >= DEDUP_THRESHOLD then
        existing.content = content
        existing.timestamp = timestamp
        existing.hit_count = (existing.hit_count or 0) + 1
        existing.updated_at = timestamp
        M.save()
        return existing.id
      end
    end
  end

  local memory = {
    id = string.format(
      'daily-%s-%s',
      get_date_key(),
      math.random(1000, 9999)
    ),
    session = session,
    role = role,
    content = content,
    timestamp = timestamp,
    date_key = get_date_key(),
    expiry_days = config.config.memory.daily.retention_days,
    hit_count = 1,
    updated_at = timestamp,
    metadata = {},
  }
  table.insert(daily_memories, memory)
  M.save()
  return memory.id
end

-- 检索日常记忆
function M.retrieve(query, limit)
  local scored = {}
  for _, memory in ipairs(daily_memories) do
    local sim = similarity.text_similarity(query, memory.content)
    if sim >= config.config.memory.daily.similarity_threshold then
      local age_days = (os.time() - memory.timestamp) / 86400
      local recency_bonus = math.max(0, (7 - age_days) / 7) * 0.2
      table.insert(scored, {
        memory = memory,
        priority = sim + recency_bonus,
      })
    end
  end
  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)
  local results = vim.tbl_map(function(item)
    local mem = item.memory
    mem.priority = item.priority
    return mem
  end, vim.list_slice(scored, 1, limit))
  return results
end

-- 清理过期记忆
function M.cleanup_expired()
  local cutoff_time = os.time()
    - (config.config.memory.daily.retention_days * 86400)
  daily_memories = vim.tbl_filter(function(mem)
    return mem.timestamp >= cutoff_time
  end, daily_memories)
  M.save()
end

-- 文本相似度（委托给公共模块，保持向后兼容）
function M.text_similarity(query, content)
  return similarity.text_similarity(query, content)
end

-- 加载/保存
function M.load()
  local path = config.get_memory_storage_dir() .. 'daily_memories.json'
  local file = io.open(path, 'r')
  if file then
    local ok, data = pcall(vim.json.decode, file:read('*a'))
    file:close()
    if ok then
      daily_memories = data
    end
  end
end

function M.save()
  local path = config.get_memory_storage_dir() .. 'daily_memories.json'
  local file = io.open(path, 'w')
  if file then
    file:write(vim.json.encode(daily_memories))
    file:close()
  end
end
-- 获取所有日常记忆
function M.get_all()
  return vim.tbl_map(function(m)
    return {
      id = m.id,
      content = m.content,
      session = m.session,
      timestamp = m.timestamp,
    }
  end, daily_memories)
end

-- 删除指定记忆
function M.delete(id)
  local count_before = #daily_memories
  daily_memories = vim.tbl_filter(function(mem)
    return mem.id ~= id
  end, daily_memories)

  if #daily_memories < count_before then
    M.save()
    return true
  end
  return false
end

-- 获取统计信息
function M.get_stats()
  return {
    total = #daily_memories,
    expired = #vim.tbl_filter(function(m)
      return m.expired
    end, daily_memories),
  }
end

M.load()
return M


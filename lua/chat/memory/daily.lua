-- lua/chat/memory/daily.lua
local M = {}

local config = require('chat.config')
local similarity = require('chat.memory.similarity')
local atomic = require('chat.memory.atomic')

local daily_memories = {}

-- 去重阈值：相似度 >= 0.85 视为同一条记忆
local DEDUP_THRESHOLD = 0.85

-- 读取配置（nil 安全：调用方可能只提供部分 memory 配置）
local function cfg()
  local memory_config = config.config.memory
  return (memory_config and memory_config.daily) or {}
end

-- 获取当天日期键
local function get_date_key(timestamp)
  return os.date('%Y-%m-%d', timestamp or os.time())
end

-- 该记忆的存活天数。存入时快照 expiry_days，之后改配置不会追溯
-- 影响已经存在的记忆。
local function get_expiry_days(mem)
  return mem.expiry_days or cfg().retention_days or 7
end

local function is_expired(mem, now)
  return (now - (mem.timestamp or 0)) >= get_expiry_days(mem) * 86400
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

-- 存储日常记忆
function M.store(session, role, content, metadata)
  if cfg().enable == false then
    return nil
  end

  local timestamp = os.time()

  -- 去重检查：相似度 >= 0.85 则更新已有记忆
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
    expiry_days = cfg().retention_days,
    hit_count = 1,
    updated_at = timestamp,
    metadata = metadata or {},
  }
  table.insert(daily_memories, memory)

  -- 数量上限（与 long_term / working 一致）
  local max_memories = cfg().max_memories or 100
  if #daily_memories > max_memories then
    -- 访问次数多的优先保留，其次保留较新的
    table.sort(daily_memories, function(a, b)
      local ha, hb = a.hit_count or 0, b.hit_count or 0
      if ha ~= hb then
        return ha > hb
      end
      return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    daily_memories = vim.list_slice(daily_memories, 1, max_memories)
  end

  M.save()
  return memory.id
end

-- 检索日常记忆
function M.retrieve(query, limit)
  if cfg().enable == false then
    return {}
  end

  limit = limit or 5
  local threshold = cfg().similarity_threshold or 0.4
  local weight = cfg().priority_weight or 1.5
  local now = os.time()
  local scored = {}

  for _, memory in ipairs(daily_memories) do
    -- 过期记忆不参与检索
    if not is_expired(memory, now) then
      local sim = similarity.text_similarity(query, memory.content)
      if sim >= threshold then
        local age_days = (now - memory.timestamp) / 86400
        local recency_bonus = math.max(0, (7 - age_days) / 7) * 0.2
        -- 权重只在这里乘一次，chat.memory.init 不再叠加
        table.insert(scored, {
          memory = memory,
          priority = (sim + recency_bonus) * weight,
        })
      end
    end
  end

  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)

  local results = {}
  for i = 1, math.min(#scored, limit) do
    table.insert(results, to_view(scored[i].memory, scored[i].priority))
  end

  return results
end

-- 清理过期记忆（按每条记忆自己的 expiry_days）
function M.cleanup_expired()
  local now = os.time()
  local count_before = #daily_memories

  daily_memories = vim.tbl_filter(function(mem)
    return not is_expired(mem, now)
  end, daily_memories)

  local removed = count_before - #daily_memories
  if removed > 0 then
    M.save()
  end

  return removed
end

-- 文本相似度（委托给公共模块，保持向后兼容）
function M.text_similarity(query, content)
  return similarity.text_similarity(query, content)
end

-- 加载/保存
function M.load()
  local path = config.get_memory_storage_dir() .. 'daily_memories.json'
  local file = io.open(path, 'r')

  -- 文件不存在时必须清空内存态。只 return 会把上一个存储目录
  -- （或上一轮测试）的数据留在内存里。
  if not file then
    daily_memories = {}
    return
  end

  local ok, data = pcall(vim.json.decode, file:read('*a'))
  file:close()
  if ok and type(data) == 'table' then
    daily_memories = data
  else
    daily_memories = {}
  end
end

-- 保存（原子写入，rename 失败时回退直接写，见 chat.memory.atomic）
function M.save()
  local storage_dir = config.get_memory_storage_dir()
  if not storage_dir then
    return false
  end

  if vim.fn.isdirectory(storage_dir) == 0 then
    vim.fn.mkdir(storage_dir, 'p')
  end

  local path = storage_dir .. 'daily_memories.json'
  return atomic.atomic_write(path, vim.json.encode(daily_memories))
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
  local now = os.time()

  return {
    total = #daily_memories,
    -- 现算：daily 从不写 m.expired 标记，之前恒为 0
    expired = #vim.tbl_filter(function(m)
      return is_expired(m, now)
    end, daily_memories),
  }
end

M.load()

-- 定时清理过期记忆（每小时执行一次）
vim.loop.new_timer():start(3600000, 3600000, function()
  vim.schedule(function()
    M.cleanup_expired()
  end)
end)

return M


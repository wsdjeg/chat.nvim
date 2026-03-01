-- lua/chat/memory/daily.lua
local M = {}
local config = require('chat.config')
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
  local memory = {
    id = string.format('daily-%s-%s', get_date_key(), math.random(1000, 9999)),
    session = session,
    role = role,
    content = content,
    timestamp = timestamp,
    date_key = get_date_key(),
    expiry_days = config.config.memory.daily.retention_days,
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
    local similarity = M.text_similarity(query, memory.content)
    if similarity >= config.config.memory.daily.similarity_threshold then
      local age_days = (os.time() - memory.timestamp) / 86400
      local recency_bonus = math.max(0, (7 - age_days) / 7) * 0.2
      table.insert(scored, {
        memory = memory,
        priority = similarity + recency_bonus,
      })
    end
  end
  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)
  return vim.tbl_map(function(item)
    return item.memory
  end, vim.list_slice(scored, 1, limit))
end

-- 清理过期记忆
function M.cleanup_expired()
  local cutoff_time = os.time() - (config.config.memory.daily.retention_days * 86400)
  daily_memories = vim.tbl_filter(function(mem)
    return mem.timestamp >= cutoff_time
  end, daily_memories)
  M.save()
end

-- 文本相似度（示意实现；可复用现有实现）
function M.text_similarity(query, content)
  if not query or not content then return 0 end
  local q, c = query:lower(), content:lower()
  if q == c then return 1.0 end
  if c:find(q, 1, true) then return 0.8 end
  return 0.4 -- 简化示意，实际可复用 memory.lua 的算法
end

-- 加载/保存
function M.load()
  local path = (config.config.memory.storage_dir or '') .. 'daily_memories.json'
  local file = io.open(path, 'r')
  if file then
    local ok, data = pcall(vim.json.decode, file:read('*a'))
    file:close()
    if ok then daily_memories = data end
  end
end

function M.save()
  local path = (config.config.memory.storage_dir or '') .. 'daily_memories.json'
  local file = io.open(path, 'w')
  if file then
    file:write(vim.json.encode(daily_memories))
    file:close()
  end
end

M.load()
return M


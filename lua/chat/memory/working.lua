-- lua/chat/memory/working.lua
local M = {}
local config = require('chat.config')
local sessions = require('chat.sessions')

local working_memories = {}
local current_session = nil

-- 生成工作记忆ID
local function generate_id()
  return string.format('work-%s-%s', os.date('%H%M%S'), math.random(100, 999))
end

-- 获取当前会话ID
local function get_current_session()
  -- 尝试从 sessions 模块获取
  if sessions and sessions.get_current_session then
    return sessions.get_current_session()
  end
  
  -- 回退：使用当前时间的简化ID
  return current_session or os.date('%Y%m%d-%H%M')
end

-- 设置当前会话（供外部调用）
function M.set_session(session_id)
  current_session = session_id
end

-- 存储工作记忆
function M.store(session, role, content, metadata)
  if not config.config.memory.working.enable then
    return nil
  end

  -- 使用当前会话如果未指定
  session = session or get_current_session()
  
  local memory = {
    id = generate_id(),
    session = session,
    role = role,
    content = content,
    timestamp = os.time(),
    priority = 1.0, -- 基础优先级
    metadata = metadata or {
      type = 'general', -- general, task, decision, context, issue
      importance = 'normal', -- low, normal, high, critical
    },
    ttl = 3600, -- 默认1小时存活时间
    created_at = os.time(),
  }

  table.insert(working_memories, memory)

  -- 限制工作记忆数量
  local max_memories = config.config.memory.working.max_memories or 20
  if #working_memories > max_memories then
    -- 移除最旧且优先级最低的记忆
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

-- 检索工作记忆
function M.retrieve(query, limit)
  if not config.config.memory.working.enable then
    return {}
  end

  limit = limit or 10
  local current_session = get_current_session()
  local scored = {}
  local now = os.time()

  for _, memory in ipairs(working_memories) do
    -- 检查是否过期
    if now - memory.created_at > memory.ttl then
      -- 标记为过期，后续清理
      memory.expired = true
      goto continue
    end

    -- 计算相似度
    local similarity = M.text_similarity(query, memory.content)
    
    -- 会话相关性加成
    local session_bonus = 0
    if memory.session == current_session then
      session_bonus = 0.3
    end

    -- 重要性加成
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

    -- 时间衰减（越新越重要）
    local age_minutes = (now - memory.timestamp) / 60
    local recency_bonus = math.max(0, (60 - age_minutes) / 60) * 0.2

    -- 总优先级
    local total_priority = similarity + session_bonus + importance_bonus + recency_bonus

    if total_priority > 0 then
      table.insert(scored, {
        memory = memory,
        priority = total_priority,
      })
    end

    ::continue::
  end

  -- 按优先级排序
  table.sort(scored, function(a, b)
    return a.priority > b.priority
  end)

  -- 返回结果
  local results = {}
  for i = 1, math.min(#scored, limit) do
    -- 应用工作记忆权重倍数
    local mem = scored[i].memory
    mem.priority = scored[i].priority * (config.config.memory.working.priority_weight or 2.0)
    table.insert(results, mem)
  end

  return results
end

-- 获取指定会话的所有工作记忆
function M.get_session_memories(session)
  session = session or get_current_session()
  
  return vim.tbl_filter(function(mem)
    return mem.session == session and not mem.expired
  end, working_memories)
end

-- 清理过期记忆
function M.cleanup_expired()
  local now = os.time()
  local count_before = #working_memories
  
  working_memories = vim.tbl_filter(function(mem)
    return (now - mem.created_at) <= mem.ttl
  end, working_memories)
  
  local removed = count_before - #working_memories
  if removed > 0 then
    M.save()
  end
  
  return removed
end

-- 清理指定会话的工作记忆
function M.cleanup_session(session)
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

-- 更新记忆重要性
function M.update_importance(memory_id, importance)
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

-- 延长记忆存活时间
function M.extend_ttl(memory_id, additional_seconds)
  for _, mem in ipairs(working_memories) do
    if mem.id == memory_id then
      mem.ttl = mem.ttl + (additional_seconds or 3600)
      mem.timestamp = os.time() -- 刷新时间戳
      M.save()
      return true
    end
  end
  return false
end

-- 标记任务完成
function M.mark_completed(memory_id, notes)
  for _, mem in ipairs(working_memories) do
    if mem.id == memory_id then
      mem.metadata = mem.metadata or {}
      mem.metadata.completed = true
      mem.metadata.completed_at = os.time()
      mem.metadata.notes = notes or mem.metadata.notes
      mem.metadata.importance = 'low' -- 完成的任务降低优先级
      M.save()
      return true
    end
  end
  return false
end

-- 获取统计信息
function M.get_stats(session)
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
      
      -- 按类型统计
      local mem_type = mem.metadata and mem.metadata.type or 'general'
      stats.by_type[mem_type] = (stats.by_type[mem_type] or 0) + 1
      
      -- 按重要性统计
      local importance = mem.metadata and mem.metadata.importance or 'normal'
      stats.by_importance[importance] = (stats.by_importance[importance] or 0) + 1
      
      -- 当前会话统计
      if mem.session == session then
        stats.by_session = stats.by_session + 1
      end
    else
      stats.expired = stats.expired + 1
    end
  end
  
  return stats
end

-- 文本相似度计算（复用现有实现）
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
    -- 中文字符（简单的二元语法）
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

-- 加载工作记忆
function M.load()
  if not config.config.memory.storage_dir then
    return
  end

  local path = vim.fs.normalize(config.config.memory.storage_dir .. '/working_memories.json')
  local file = io.open(path, 'r')
  
  if not file then
    working_memories = {}
    return
  end

  local content = file:read('*a')
  io.close(file)

  local ok, parsed = pcall(vim.json.decode, content)
  if ok and type(parsed) == 'table' then
    working_memories = parsed
  else
    working_memories = {}
  end
  
  -- 加载后自动清理过期记忆
  M.cleanup_expired()
end

-- 保存工作记忆
function M.save()
  if not config.config.memory.storage_dir then
    return
  end

  -- 确保目录存在
  if vim.fn.isdirectory(config.config.memory.storage_dir) == 0 then
    vim.fn.mkdir(config.config.memory.storage_dir, 'p')
  end

  local path = vim.fs.normalize(config.config.memory.storage_dir .. '/working_memories.json')
  local file = io.open(path, 'w')
  
  if file then
    file:write(vim.json.encode(working_memories))
    io.close(file)
  end
end

-- 删除指定记忆
function M.delete(memory_id)
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

-- 清空所有工作记忆
function M.clear()
  working_memories = {}
  M.save()
end

-- 导出工作记忆到长期记忆
function M.promote_to_long_term(memory_id)
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
  
  -- 调用长期记忆模块存储
  local long_term = require('chat.memory.long_term')
  local long_term_id = long_term.store(memory.session, memory.role, memory.content)
  
  if long_term_id then
    -- 标记为已导出
    memory.metadata = memory.metadata or {}
    memory.metadata.promoted = true
    memory.metadata.promoted_to = long_term_id
    M.save()
    return long_term_id
  end
  
  return nil, 'Failed to promote to long-term memory'
end

-- 初始化
M.load()

-- 设置定期清理（每5分钟）
vim.loop.new_timer():start(300000, 300000, function()
  vim.schedule(function()
    M.cleanup_expired()
  end)
end)

return M


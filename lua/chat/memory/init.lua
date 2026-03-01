-- lua/chat/memory/init.lua
local M = {}
local long_term = require('chat.memory.long_term')
local daily = require('chat.memory.daily')
local working = require('chat.memory.working')

-- 存储记忆（根据类型自动路由）
function M.store_memory(session, role, content, memory_type)
  memory_type = memory_type or 'long_term'
  if memory_type == 'long_term' then
    return long_term.store(session, role, content)
  elseif memory_type == 'daily' then
    return daily.store(session, role, content)
  elseif memory_type == 'working' then
    return working.store(session, role, content)
  end
end

-- 智能检索（合并三种记忆，按权重排序）
function M.retrieve_memories(query, session, limit)
  local results = {}

  -- 1. 检索工作记忆（最高优先级）
  local working_memories = working.retrieve(query, limit)
  for _, mem in ipairs(working_memories) do
    mem.priority = (mem.priority or 1.0) * 2.0
    table.insert(results, mem)
  end

  -- 2. 检索日常记忆
  local daily_memories = daily.retrieve(query, limit)
  for _, mem in ipairs(daily_memories) do
    mem.priority = (mem.priority or 1.0) * 1.5
    table.insert(results, mem)
  end

  -- 3. 检索长期记忆
  local long_memories = long_term.retrieve(query, session, limit)
  for _, mem in ipairs(long_memories) do
    mem.priority = mem.priority or 1.0
    table.insert(results, mem)
  end

  -- 按优先级排序
  table.sort(results, function(a, b)
    return a.priority > b.priority
  end)

  return vim.list_slice(results, 1, limit)
end

-- 清理过期记忆
function M.cleanup()
  long_term.cleanup()
  daily.cleanup_expired()
  working.cleanup_session()
end

-- 获取所有记忆（兼容旧接口）
function M.get_memories()
  local all_memories = {}

  -- 合并三种记忆
  vim.list_extend(all_memories, working.get_session_memories())
  vim.list_extend(all_memories, daily.get_all())
  vim.list_extend(all_memories, long_term.get_all())

  return all_memories
end

-- 删除记忆（兼容旧接口）
function M.delete(id)
  -- 根据ID前缀判断类型
  if id:match('^work%-') then
    return working.delete(id)
  elseif id:match('^daily%-') then
    return daily.delete(id)
  else
    return long_term.delete(id)
  end
end

-- 清理会话记忆（兼容旧接口）
function M.clear_session_memories(session)
  working.cleanup_session(session)
  -- 注意：daily 和 long_term 可能不需要按会话清理
  -- 可以根据需求决定是否清理
end

-- 获取统计信息（可选）
function M.get_stats()
  return {
    working = working.get_stats(),
    daily = daily.get_stats(),
    long_term = long_term.get_stats(),
  }
end

return M

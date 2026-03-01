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
    mem.priority = mem.priority * 2.0
    table.insert(results, mem)
  end

  -- 2. 检索日常记忆
  local daily_memories = daily.retrieve(query, limit)
  for _, mem in ipairs(daily_memories) do
    mem.priority = mem.priority * 1.5
    table.insert(results, mem)
  end

  -- 3. 检索长期记忆
  local long_memories = long_term.retrieve(query, limit)
  for _, mem in ipairs(long_memories) do
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

return M


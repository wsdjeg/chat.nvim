-- lua/chat/memory/init.lua
local M = {}

local config = require('chat.config')

local long_term = require('chat.memory.long_term')
local daily = require('chat.memory.daily')
local working = require('chat.memory.working')

-- 检索派发表。
--
-- 三个模块的 retrieve 签名本来就不一致（daily/working 只按“当前会话”
-- 取数，long_term 接受显式 session 过滤），这里保持各自语义，不做统一
-- 改造 —— 统一会改变既有检索行为。
local RETRIEVERS = {
  working = function(query, _session, limit)
    return working.retrieve(query, limit)
  end,
  daily = function(query, _session, limit)
    return daily.retrieve(query, limit)
  end,
  long_term = function(query, session, limit)
    return long_term.retrieve(query, session, limit)
  end,
}

local STORES = {
  working = working,
  daily = daily,
  long_term = long_term,
}

-- 全局开关的唯一收口点：工具入口、plan 自动写入都走这里，
-- 不需要每个调用点各自检查 memory.enable。
local function is_enabled()
  return config.config.memory and config.config.memory.enable == true
end

---存储记忆（根据类型自动路由）
---@param session string 会话 ID
---@param role string 'user' | 'system' | ...
---@param content string 记忆内容
---@param memory_type? string 'long_term' | 'daily' | 'working'
---@param metadata? table 模块自定义元数据（working 支持 type/importance）
---@return string|nil 记忆 ID
function M.store_memory(session, role, content, memory_type, metadata)
  if not is_enabled() then
    return nil
  end

  memory_type = memory_type or 'long_term'
  local store = STORES[memory_type]
  if not store then
    return nil
  end

  return store.store(session, role, content, metadata)
end

---智能检索（合并三种记忆，按模块给出的 priority 排序）
---
---各模块自己乘 priority_weight（working 2.0 / daily 1.5 / long_term 1.0），
---这里不再叠加任何权重，否则会变成 4x / 2.25x。
---
---@param query string 检索词
---@param session? string 会话 ID，nil 表示不限会话
---@param limit? number 结果条数上限
---@param opts? { memory_type?: string } 指定类型时只在目标模块内检索
---@return table[] 检索视图列表
function M.retrieve_memories(query, session, limit, opts)
  if not is_enabled() then
    return {}
  end

  opts = opts or {}
  limit = limit or 5

  -- 指定类型时只查目标模块。跨类型取 top-N 之后再过滤会丢结果：
  -- 目标类型的记忆可能排在第 N 名之外，过滤后就是空。
  local types = opts.memory_type and { opts.memory_type }
    or { 'working', 'daily', 'long_term' }

  local results = {}
  for _, memory_type in ipairs(types) do
    local retrieve = RETRIEVERS[memory_type]
    if retrieve then
      local memories = retrieve(query, session, limit)
      vim.list_extend(results, memories or {})
    end
  end

  -- 模块层已算好最终优先级，这里只排序
  table.sort(results, function(a, b)
    return (a.priority or 0) > (b.priority or 0)
  end)

  return vim.list_slice(results, 1, limit)
end

---清理过期/陈旧记忆
---
---只清 TTL 过期与陈旧记录，**不**按会话清空工作记忆：
---那会删掉当前会话所有未过期记忆，语义危险。
---按会话清理请用 clear_session_memories(session)。
function M.cleanup()
  if not is_enabled() then
    return
  end

  long_term.cleanup()
  daily.cleanup_expired()
  working.cleanup_expired()
end

-- 获取所有记忆（兼容旧接口）
function M.get_memories()
  local all_memories = {}

  -- 合并三种记忆
  vim.list_extend(all_memories, working.get_all())
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
  if not session then
    return nil
  end

  return working.cleanup_session(session)
end

-- 获取统计信息（可选）
function M.get_stats()
  return {
    working = working.get_stats(),
    daily = daily.get_stats(),
    long_term = long_term.get_stats(),
  }
end

---关闭三个记忆模块的定时维护任务
---
---定时器句柄由各模块持有（见 chat.memory.persist），插件卸载或测试清理时
---调用这里，避免回调在已删除的存储目录上继续触发。
function M.shutdown()
  long_term.stop_cleanup_timer()
  daily.stop_cleanup_timer()
  working.stop_cleanup_timer()
end

return M


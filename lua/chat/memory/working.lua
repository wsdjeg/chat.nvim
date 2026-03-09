local M = {}
local config = require('chat.config')

local working_memories = {}

-- Generate working memory ID
local function generate_id()
  return string.format('work-%s-%s', os.date('%H%M%S'), math.random(100, 999))
end

local function get_current_session()
  return require('chat.windows').current_session()
end

function M.get_all()
  return vim.tbl_filter(function(mem)
    return not mem.expired
  end, working_memories)
end

-- Store working memory
function M.store(session, role, content, metadata)
  if not config.config.memory.working.enable then
    return nil
  end

  -- Use current session if not specified
  session = session or get_current_session()

  local memory = {
    id = generate_id(),
    session = session,
    role = role,
    content = content,
    timestamp = os.time(),
    priority = 1.0, -- Base priority
    metadata = metadata or {
      type = 'general', -- general, task, decision, context, issue
      importance = 'normal', -- low, normal, high, critical
    },
    ttl = 3600, -- Default 1 hour TTL (time-to-live)
    created_at = os.time(),
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

  limit = limit or 10
  local session = get_current_session()
  local scored = {}
  local now = os.time()

  for _, memory in ipairs(working_memories) do
    -- Check if expired
    if now - memory.created_at > memory.ttl then
      -- Mark as expired, cleanup later
      memory.expired = true
      goto continue
    end

    -- Calculate similarity
    local similarity = M.text_similarity(query, memory.content)

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
    local age_minutes = (now - memory.timestamp) / 60
    local recency_bonus = math.max(0, (60 - age_minutes) / 60) * 0.2

    -- Total priority
    local total_priority = similarity
      + session_bonus
      + importance_bonus
      + recency_bonus

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

  -- Return results
  local results = {}
  for i = 1, math.min(#scored, limit) do
    -- Apply working memory weight multiplier
    local mem = scored[i].memory
    mem.priority = scored[i].priority
      * (config.config.memory.working.priority_weight or 2.0)
    table.insert(results, mem)
  end

  return results
end

-- Get all working memories for specified session
function M.get_session_memories(session)
  session = session or get_current_session()

  return vim.tbl_filter(function(mem)
    return mem.session == session and not mem.expired
  end, working_memories)
end

-- Cleanup expired memories
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

-- Cleanup working memories for specified session
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

-- Update memory importance
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

-- Extend memory TTL
function M.extend_ttl(memory_id, additional_seconds)
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

-- Text similarity calculation (reuse existing implementation)
function M.text_similarity(query, content)
  if not query or not content then
    return 0
  end

  local query_lower = query:lower()
  local content_lower = content:lower()

  -- Exact match
  if query_lower == content_lower then
    return 1.0
  end

  -- Substring match
  if content_lower:find(query_lower, 1, true) then
    return 0.8
  end

  -- Tokenization match
  local function split_words(text)
    local words = {}
    -- English words
    for word in text:gmatch('%w+') do
      words[word:lower()] = true
    end
    -- Chinese characters (simple bigram)
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

-- Load working memories
function M.load()
  if not config.config.memory.storage_dir then
    return
  end

  local path = vim.fs.normalize(
    config.config.memory.storage_dir .. '/working_memories.json'
  )
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

  -- Auto cleanup expired memories after loading
  M.cleanup_expired()
end

-- Save working memories
function M.save()
  if not config.config.memory.storage_dir then
    return
  end

  -- Ensure directory exists
  if vim.fn.isdirectory(config.config.memory.storage_dir) == 0 then
    vim.fn.mkdir(config.config.memory.storage_dir, 'p')
  end

  local path = vim.fs.normalize(
    config.config.memory.storage_dir .. '/working_memories.json'
  )
  local file = io.open(path, 'w')

  if file then
    file:write(vim.json.encode(working_memories))
    io.close(file)
  end
end

-- Delete specified memory
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

-- Clear all working memories
function M.clear()
  working_memories = {}
  M.save()
end

-- Promote working memory to long-term memory
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

-- Initialize
M.load()

-- Setup periodic cleanup (every 5 minutes)
vim.loop.new_timer():start(300000, 300000, function()
  vim.schedule(function()
    M.cleanup_expired()
  end)
end)

return M

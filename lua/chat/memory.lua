local M = {}
local sessions = require('chat.sessions')
local config = require('chat.config')

local memories = {}

function M.get_memories()
  return vim.tbl_map(function(m)
    return {
      id = m.id,
      content = m.content,
      session = m.session,
    }
  end, memories)
end

function M.delete(id)
  memories = vim.tbl_filter(function(t)
    return t.id ~= id
  end, memories)
  M.save_memories()
end

function M.init_storage()
  if vim.fn.isdirectory(config.config.memory.storage_dir) == 0 then
    vim.fn.mkdir(config.config.memory.storage_dir, 'p')
  end
end

function M.get_memories_path()
  return vim.fs.normalize(
    config.config.memory.storage_dir .. '/memories.json'
  )
end

function M.load_memories()
  if not vim.tbl_isempty(memories) then
    return memories
  end
  local file = io.open(M.get_memories_path(), 'r')
  if not file then
    memories = {}
    return memories
  end

  local content = file:read('*a')
  io.close(file)

  local ok, parsed = pcall(vim.json.decode, content)
  if ok and type(parsed) == 'table' then
    memories = parsed
  else
    memories = {}
  end
  return memories
end

function M.save_memories()
  local file = io.open(M.get_memories_path(), 'w')
  if file then
    file:write(vim.json.encode(memories))
    io.close(file)
  end
end

function M.generate_id()
  local MEMORY_ID_STRFTIME_FORMAT = '%Y-%m-%d-%H-%M-%S'
  return string.format(
    '%s-%s',
    os.date(MEMORY_ID_STRFTIME_FORMAT),
    math.random(1000, 9999)
  )
end

function M.store_memory(session, role, content)
  if not config.config.memory.enable then
    return nil
  end

  local memory = {
    id = M.generate_id(),
    session = session,
    role = role,
    content = content,
    timestamp = os.time(),
    metadata = {
      provider = sessions.get_session_provider(session),
      model = sessions.get_session_model(session),
      cwd = sessions.getcwd(session),
    },
  }

  table.insert(memories, memory)

  if #memories > config.config.memory.max_memories then
    table.sort(memories, function(a, b)
      return a.timestamp < b.timestamp
    end)
    memories = vim.list_slice(
      memories,
      #memories - config.config.memory.max_memories + 1,
      #memories
    )
  end

  M.save_memories()
  return memory.id
end

local function split_words(text)
  local words = {}
  for word in text:gmatch('%w+') do
    words[word:lower()] = true
  end
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

function M.text_similarity(query, content)
  if not query or not content then
    return 0
  end

  local query_lower = query:lower()
  local content_lower = content:lower()

  if query_lower == content_lower then
    return 1.0
  end

  if content_lower:find(query_lower, 1, true) then
    return 0.8
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

function M.retrieve_memories(query, session, limit)
  if not config.config.memory.enable then
    return {}
  end

  local scored = {}

  for _, memory in ipairs(memories) do
    if not session or memory.session == session then
      local similarity = M.text_similarity(query, memory.content)
      if similarity >= config.config.memory.similarity_threshold then
        table.insert(scored, {
          memory = memory,
          similarity = similarity,
        })
      end
    end
  end

  table.sort(scored, function(a, b)
    return a.similarity > b.similarity
  end)

  local results = {}
  for i = 1, math.min(#scored, limit or config.config.memory.retrieval_limit) do
    table.insert(results, scored[i].memory)
  end

  return results
end

function M.clear_session_memories(session)
  memories = vim.tbl_filter(function(memory)
    return memory.session ~= session
  end, memories)
  M.save_memories()
end

function M.get_stats()
  local stats = {
    total = #memories,
    by_role = { user = 0, assistant = 0 },
  }

  for _, memory in ipairs(memories) do
    if memory.role == 'user' then
      stats.by_role.user = stats.by_role.user + 1
    elseif memory.role == 'assistant' then
      stats.by_role.assistant = stats.by_role.assistant + 1
    end
  end

  return stats
end

M.init_storage()
M.load_memories()

return M

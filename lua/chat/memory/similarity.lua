-- lua/chat/memory/similarity.lua
-- Shared text similarity calculation for all memory modules.
-- Supports English words, Chinese bigrams, substring matching,
-- and Levenshtein distance as a fallback for fuzzy matching.

local M = {}

---Split text into word tokens (set).
---Supports English words and Chinese character bigrams.
---@param text string
---@return table<string, boolean>
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

---Calculate Levenshtein distance between two strings.
---@param s1 string
---@param s2 string
---@return number
local function levenshtein(s1, s2)
  local len1, len2 = #s1, #s2
  if len1 == 0 then
    return len2
  end
  if len2 == 0 then
    return len1
  end

  -- Use two rows for O(n) space
  local prev = {}
  local curr = {}

  for j = 0, len2 do
    prev[j] = j
  end

  for i = 1, len1 do
    curr[0] = i
    for j = 1, len2 do
      local cost = (s1:sub(i, i) == s2:sub(j, j)) and 0 or 1
      curr[j] = math.min(
        curr[j - 1] + 1,    -- insertion
        prev[j] + 1,        -- deletion
        prev[j - 1] + cost  -- substitution
      )
    end
    -- Swap rows
    prev, curr = curr, prev
  end

  return prev[len2]
end

---Calculate normalized Levenshtein similarity (0-1).
---@param s1 string
---@param s2 string
---@return number
local function levenshtein_similarity(s1, s2)
  if not s1 or not s2 or s1 == '' or s2 == '' then
    return 0
  end
  local max_len = math.max(#s1, #s2)
  if max_len == 0 then
    return 1
  end
  local dist = levenshtein(s1, s2)
  return 1 - (dist / max_len)
end

---Calculate text similarity between query and content.
---Returns a score from 0 to 1.
---
---Strategy (best score wins):
---1. Exact match -> 1.0
---2. Substring match -> 0.8
---3. Token overlap (Jaccard-like) -> 0..1
---4. Levenshtein similarity (fuzzy) -> 0..1, scaled by 0.6
---
---@param query string|nil
---@param content string|nil
---@return number
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

  -- Token overlap
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

  local token_score = 0
  if total > 0 then
    token_score = matches / total
  end

  -- Levenshtein similarity as fuzzy fallback (scaled down)
  local fuzzy_score = levenshtein_similarity(query_lower, content_lower) * 0.6

  -- Return the best score
  return math.max(token_score, fuzzy_score)
end

---Find the best matching content from a list.
---@param query string
---@param contents table List of {content=string, ...} entries
---@param threshold number Minimum similarity to consider a match
---@return table|nil best_entry, number|nil best_score
function M.find_best_match(query, contents, threshold)
  threshold = threshold or 0.3
  local best_entry = nil
  local best_score = 0

  for _, entry in ipairs(contents) do
    local content = entry.content or entry
    local score = M.text_similarity(query, content)
    if score > best_score then
      best_score = score
      best_entry = entry
    end
  end

  if best_score >= threshold then
    return best_entry, best_score
  end
  return nil, nil
end

return M


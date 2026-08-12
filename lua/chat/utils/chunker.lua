-- lua/chat/utils/chunker.lua
-- Markdown-aware message chunker
--
-- Splits long messages at safe boundaries, preserving Markdown structures.
-- Splitting priority:
--   1. Paragraph boundaries (\n\n)
--   2. Block boundaries (before/after code blocks, tables)
--   3. Line boundaries (\n) within oversized blocks
--   4. Word boundaries (space)
--   5. Hard truncation (last resort)

local M = {}

--- Platform-specific message length limits
M.Limits = {
  DISCORD = 2000,
  TELEGRAM = 4096,
  WECHAT = 2048,
  WECOM = 2048,
  SLACK = 40000,
  DINGTALK = 20000,
  LARK = 30720,
}

--- Parse content into blocks.
--- Each block: { text = string, type = "code_block"|"table"|"paragraph" }
---@param content string
---@return table[]
local function parse_blocks(content)
  local blocks = {}
  local lines = vim.split(content, '\n', { plain = true })
  local i = 1

  while i <= #lines do
    local line = lines[i]

    if line == '' then
      -- Blank line: skip (acts as separator)
      i = i + 1
    elseif line:match('^%s*```') then
      -- Code block: consume until closing ```
      local block_lines = { line }
      i = i + 1
      while i <= #lines do
        table.insert(block_lines, lines[i])
        if lines[i]:match('^%s*```') then
          i = i + 1
          break
        end
        i = i + 1
      end
      table.insert(blocks, {
        text = table.concat(block_lines, '\n'),
        type = 'code_block',
      })
    elseif line:match('^|') then
      -- Table: consume consecutive lines starting with |
      local block_lines = { line }
      i = i + 1
      while i <= #lines and lines[i]:match('^|') do
        table.insert(block_lines, lines[i])
        i = i + 1
      end
      table.insert(blocks, {
        text = table.concat(block_lines, '\n'),
        type = 'table',
      })
    else
      -- Paragraph: consume until blank line or special block
      local block_lines = { line }
      i = i + 1
      while
        i <= #lines
        and lines[i] ~= ''
        and not lines[i]:match('^|')
        and not lines[i]:match('^%s*```')
      do
        table.insert(block_lines, lines[i])
        i = i + 1
      end
      table.insert(blocks, {
        text = table.concat(block_lines, '\n'),
        type = 'paragraph',
      })
    end
  end

  return blocks
end

--- Extract header from a table block (header row + separator row).
---@param lines string[]  Table lines
---@return string|nil header  "header_row\nseparator_row" or nil
local function extract_table_header(lines)
  if #lines >= 2 and lines[2]:match('^[%s|%:-]+$') then
    return lines[1] .. '\n' .. lines[2]
  end
  return nil
end

--- Start a new table chunk with header (if it fits).
--- Falls back to emitting header alone, then line without header.
---@param chunks string[]  Chunk list to append to
---@param header string|nil  Table header
---@param line string  First data row
---@return table current  New current lines
---@return integer current_len  New current length
local function start_table_chunk(chunks, header, line, max_length)
  if header and #header + 1 + #line <= max_length then
    -- Header + line fits
    return { header, line }, #header + 1 + #line
  elseif header and #header <= max_length then
    -- Header fits alone, but header + line doesn't
    -- Emit header as its own chunk, line goes without header
    table.insert(chunks, header)
    return { line }, #line
  else
    -- Header itself doesn't fit (extreme edge case)
    return { line }, #line
  end
end

--- Split a single long line at word boundaries, then hard truncate.
---@param line string
---@param max_length integer
---@return string[]
function M._split_long_line(line, max_length)
  if #line <= max_length then
    return { line }
  end

  local chunks = {}
  local remaining = line

  while #remaining > max_length do
    -- Try to find last space within max_length
    local window = remaining:sub(1, max_length)
    local space_pos = window:reverse():find(' ')

    if space_pos then
      local split_at = max_length - space_pos + 1
      table.insert(chunks, remaining:sub(1, split_at - 1))
      remaining = remaining:sub(split_at + 1)
    else
      -- No space: hard truncate
      table.insert(chunks, remaining:sub(1, max_length))
      remaining = remaining:sub(max_length + 1)
    end
  end

  if #remaining > 0 then
    table.insert(chunks, remaining)
  end

  return chunks
end

--- Sub-split a block that exceeds max_length.
--- For tables: split between rows, repeat header in each chunk.
--- For code blocks: split between lines, close/reopen fences.
--- For paragraphs: split between lines.
---@param block table  { text, type }
---@param max_length integer
---@return string[]
local function subsplit_block(block, max_length)
  local text = block.text
  if #text <= max_length then
    return { text }
  end

  local lines = vim.split(text, '\n', { plain = true })
  local btype = block.type
  local chunks = {}
  local current = {}
  local current_len = 0

  -- Table: extract header to repeat in continuation chunks
  local header = nil
  local header_skip = 0
  if btype == 'table' then
    header = extract_table_header(lines)
    header_skip = header and 2 or 0
  end

  -- Code block: extract fence (opening ```)
  local fence = nil
  if btype == 'code_block' then
    fence = lines[1]:match('^%s*```') and lines[1] or '```'
  end

  for idx, line in ipairs(lines) do
    -- Skip table header lines (handled per-chunk)
    if idx <= header_skip then
      goto continue
    end

    local sep = current_len > 0 and 1 or 0
    local line_len = #line + sep

    if current_len + line_len > max_length and #current > 0 then
      -- Flush current chunk
      local chunk_text = table.concat(current, '\n')
      if btype == 'code_block' then
        chunk_text = chunk_text .. '\n```'
      end
      table.insert(chunks, chunk_text)

      -- Start new chunk
      current = {}
      current_len = 0

      if btype == 'table' and header then
        current, current_len = start_table_chunk(chunks, header, line, max_length)
      elseif btype == 'code_block' then
        table.insert(current, fence)
        table.insert(current, line)
        current_len = #fence + 1 + #line
      else
        table.insert(current, line)
        current_len = #line
      end
    elseif #line > max_length then
      -- Single line exceeds max_length: hard split
      -- Flush current first
      if #current > 0 then
        local ct = table.concat(current, '\n')
        if btype == 'code_block' then
          ct = ct .. '\n```'
        end
        table.insert(chunks, ct)
        current = {}
        current_len = 0
      end

      -- Budget for fence if code block
      local budget = max_length
      if btype == 'code_block' then
        budget = max_length - #fence - 8 -- room for fence + \n + closing ```
      end

      local parts = M._split_long_line(line, budget)
      for j, part in ipairs(parts) do
        if j < #parts then
          if btype == 'code_block' then
            table.insert(chunks, fence .. '\n' .. part .. '\n```')
          else
            table.insert(chunks, part)
          end
        else
          -- Last part: keep as current
          if btype == 'code_block' then
            table.insert(current, fence)
            table.insert(current, part)
            current_len = #fence + 1 + #part
          else
            table.insert(current, part)
            current_len = #part
          end
        end
      end
    else
      -- Normal line: add to current
      if #current == 0 and btype == 'table' and header then
        current, current_len = start_table_chunk(chunks, header, line, max_length)
      else
        table.insert(current, line)
        current_len = current_len + line_len
      end
    end

    ::continue::
  end

  -- Flush remaining
  if #current > 0 then
    table.insert(chunks, table.concat(current, '\n'))
  end

  -- Edge case: only header lines existed (no data rows)
  if #chunks == 0 then
    return { text }
  end

  return chunks
end

--- Chunk content into pieces, each no longer than max_length.
--- Preserves Markdown structures (tables, code blocks) when possible.
---@param content string  The content to chunk
---@param max_length integer  Maximum length per chunk
---@return string[]  Array of chunks
function M.chunk(content, max_length)
  if not content or content == '' then
    return {}
  end

  if #content <= max_length then
    return { content }
  end

  local blocks = parse_blocks(content)
  local chunks = {}
  local current_parts = {}
  local current_len = 0

  for _, block in ipairs(blocks) do
    local sep_len = current_len > 0 and 2 or 0
    local needed = sep_len + #block.text

    if current_len + needed <= max_length then
      -- Block fits in current chunk
      if current_len > 0 then
        table.insert(current_parts, '\n\n')
        current_len = current_len + 2
      end
      table.insert(current_parts, block.text)
      current_len = current_len + #block.text
    elseif #block.text <= max_length then
      -- Block fits alone but not in current chunk: flush, start new
      if #current_parts > 0 then
        table.insert(chunks, table.concat(current_parts))
        current_parts = {}
        current_len = 0
      end
      current_parts = { block.text }
      current_len = #block.text
    else
      -- Block exceeds max_length: sub-split
      if #current_parts > 0 then
        table.insert(chunks, table.concat(current_parts))
        current_parts = {}
        current_len = 0
      end

      local sub = subsplit_block(block, max_length)
      for i = 1, #sub - 1 do
        table.insert(chunks, sub[i])
      end
      -- Last sub-chunk becomes current
      current_parts = { sub[#sub] }
      current_len = #sub[#sub]
    end
  end

  -- Flush remaining
  if #current_parts > 0 then
    table.insert(chunks, table.concat(current_parts))
  end

  -- Final safety pass: ensure no chunk exceeds max_length
  local safe = {}
  for _, c in ipairs(chunks) do
    if #c <= max_length then
      table.insert(safe, c)
    else
      -- Emergency hard split (shouldn't normally happen)
      local remaining = c
      while #remaining > max_length do
        local window = remaining:sub(1, max_length)
        local pos = window:reverse():find('\n')
        if pos then
          pos = max_length - pos + 1
          table.insert(safe, remaining:sub(1, pos))
          remaining = remaining:sub(pos + 1)
        else
          pos = window:reverse():find(' ')
          if pos then
            pos = max_length - pos + 1
            table.insert(safe, remaining:sub(1, pos - 1))
            remaining = remaining:sub(pos + 1)
          else
            table.insert(safe, remaining:sub(1, max_length))
            remaining = remaining:sub(max_length + 1)
          end
        end
      end
      if #remaining > 0 then
        table.insert(safe, remaining)
      end
    end
  end

  return safe
end

return M


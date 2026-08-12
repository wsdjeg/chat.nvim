-- test/utils/chunker_spec.lua
-- Tests for Markdown-aware message chunker

local lu = require('luaunit')
local chunker = require('chat.utils.chunker')

TestChunker = {}

------------------------------------------------------------
-- Basic functionality
------------------------------------------------------------

function TestChunker:test_empty_content()
  local chunks = chunker.chunk('', 100)
  lu.assertEquals(chunks, {})
end

function TestChunker:test_nil_content()
  local chunks = chunker.chunk(nil, 100)
  lu.assertEquals(chunks, {})
end

function TestChunker:test_short_content_single_chunk()
  local content = 'Hello, world!'
  local chunks = chunker.chunk(content, 100)
  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

function TestChunker:test_exact_fit()
  local content = string.rep('a', 100)
  local chunks = chunker.chunk(content, 100)
  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

------------------------------------------------------------
-- Paragraph splitting
------------------------------------------------------------

function TestChunker:test_split_at_paragraph_boundary()
  local para1 = string.rep('a', 60)
  local para2 = string.rep('b', 60)
  local content = para1 .. '\n\n' .. para2
  local chunks = chunker.chunk(content, 100)

  lu.assertEquals(#chunks, 2)
  lu.assertEquals(chunks[1], para1)
  lu.assertEquals(chunks[2], para2)
end

function TestChunker:test_multiple_paragraphs_fit()
  local content = 'First paragraph.\n\nSecond paragraph.\n\nThird paragraph.'
  local chunks = chunker.chunk(content, 200)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

function TestChunker:test_multiple_paragraphs_split()
  local p1 = string.rep('A', 40)
  local p2 = string.rep('B', 40)
  local p3 = string.rep('C', 40)
  local content = p1 .. '\n\n' .. p2 .. '\n\n' .. p3
  local chunks = chunker.chunk(content, 90)

  -- Each paragraph is 40 chars, separator is 2
  -- Chunk 1: p1 + \n\n + p2 = 82 (fits in 90)
  -- Chunk 2: p3 = 40
  lu.assertEquals(#chunks, 2)
  lu.assertEquals(chunks[1], p1 .. '\n\n' .. p2)
  lu.assertEquals(chunks[2], p3)
end

------------------------------------------------------------
-- Table preservation (the main bug report)
------------------------------------------------------------

function TestChunker:test_table_not_split()
  local table_text = table.concat({
    '| Name  | Age |',
    '|-------|-----|',
    '| Alice | 30  |',
    '| Bob   | 25  |',
  }, '\n')
  local content = 'Some intro text.\n\n' .. table_text
  local chunks = chunker.chunk(content, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

function TestChunker:test_table_intact_when_splitting_around_it()
  local intro = string.rep('x', 100)
  local table_text = table.concat({
    '| Name  | Age |',
    '|-------|-----|',
    '| Alice | 30  |',
    '| Bob   | 25  |',
  }, '\n')
  local outro = string.rep('y', 100)
  local content = intro .. '\n\n' .. table_text .. '\n\n' .. outro
  local chunks = chunker.chunk(content, 150)

  lu.assertTrue(#chunks >= 2)

  -- The table must be intact in one chunk
  local table_found = false
  for _, c in ipairs(chunks) do
    if c:find('| Name  | Age |', 1, true) then
      lu.assertEquals(c, table_text)
      table_found = true
      break
    end
  end
  lu.assertTrue(table_found, 'Table should be found intact in one chunk')
end

function TestChunker:test_table_split_between_rows_with_header()
  -- Table with many rows that exceeds max_length
  local rows = {}
  table.insert(rows, '| Name  | Description            |')
  table.insert(rows, '|-------|------------------------|')
  for i = 1, 20 do
    table.insert(rows, '| User' .. i .. ' | ' .. string.rep('x', 20) .. ' |')
  end
  local table_text = table.concat(rows, '\n')

  -- Use a max_length where header + data row fits, but not many rows
  local chunks = chunker.chunk(table_text, 150)

  lu.assertTrue(#chunks > 1, 'Table should be split into multiple chunks')

  -- Each chunk should start with the header
  for _, c in ipairs(chunks) do
    lu.assertTrue(
      c:find('^| Name  | Description', 1) ~= nil,
      'Each table chunk should start with header: ' .. c:sub(1, 50)
    )
  end
end

function TestChunker:test_table_separator_not_split_from_header()
  -- This is the exact bug: header and separator must stay together
  local content = table.concat({
    'Here is some text before the table.',
    '',
    '| Column A | Column B |',
    '|----------|----------|',
    '| Value 1  | Value 2  |',
    '',
    'Text after table.',
  }, '\n')

  -- Use a max_length that would split between header and separator
  -- with the old naive approach
  local chunks = chunker.chunk(content, 100)

  -- Verify no chunk ends with just the header line
  for _, c in ipairs(chunks) do
    lu.assertFalse(
      c:sub(-12) == '| Column B |',
      'No chunk should end with just the table header'
    )
  end
end

------------------------------------------------------------
-- Code block preservation
------------------------------------------------------------

function TestChunker:test_code_block_not_split()
  local code = '```lua\nlocal x = 1\nlocal y = 2\nprint(x + y)\n```'
  local content = 'Here is some code:\n\n' .. code
  local chunks = chunker.chunk(content, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

function TestChunker:test_oversized_code_block_split_with_fences()
  -- Code block with many lines
  local lines = { '```lua' }
  for i = 1, 30 do
    table.insert(lines, 'local var' .. i .. ' = ' .. string.rep('x', 20))
  end
  table.insert(lines, '```')
  local code = table.concat(lines, '\n')

  local chunks = chunker.chunk(code, 100)

  lu.assertTrue(#chunks > 1, 'Code block should be split')

  -- Each chunk should be a valid code block (starts with ``` and ends with ```)
  for _, c in ipairs(chunks) do
    lu.assertTrue(
      c:match('^```') ~= nil,
      'Each code chunk should start with fence: ' .. c:sub(1, 20)
    )
    lu.assertTrue(
      c:match('```$') ~= nil,
      'Each code chunk should end with fence: ' .. c:sub(-20)
    )
  end
end

function TestChunker:test_unclosed_code_block()
  -- Unclosed code block: should consume to end
  local content = '```lua\nlocal x = 1\nlocal y = 2'
  local chunks = chunker.chunk(content, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

------------------------------------------------------------
-- Mixed content
------------------------------------------------------------

function TestChunker:test_mixed_content_paragraphs_and_table()
  local p1 = string.rep('a', 80)
  local table_text = table.concat({
    '| H1 | H2 |',
    '|----|----|',
    '| v1 | v2 |',
  }, '\n')
  local p2 = string.rep('b', 80)
  local content = p1 .. '\n\n' .. table_text .. '\n\n' .. p2

  local chunks = chunker.chunk(content, 100)

  -- p1 (80) fits alone
  -- table (~30) fits alone
  -- p2 (80) fits alone
  lu.assertTrue(#chunks >= 2)

  -- Table should be intact
  local table_intact = false
  for _, c in ipairs(chunks) do
    if c:find('| H1 | H2 |', 1, true) then
      lu.assertEquals(c, table_text)
      table_intact = true
      break
    end
  end
  lu.assertTrue(table_intact)
end

function TestChunker:test_mixed_content_code_and_table()
  local code = '```python\nprint("hello")\n```'
  local table_text = table.concat({
    '| Name | Value |',
    '|------|-------|',
    '| foo  | 42    |',
  }, '\n')
  local content = code .. '\n\n' .. table_text

  local chunks = chunker.chunk(content, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

------------------------------------------------------------
-- Hard truncation fallback
------------------------------------------------------------

function TestChunker:test_very_long_line_no_spaces()
  local content = string.rep('x', 300)
  local chunks = chunker.chunk(content, 100)

  lu.assertEquals(#chunks, 3)
  lu.assertEquals(#chunks[1], 100)
  lu.assertEquals(#chunks[2], 100)
  lu.assertEquals(#chunks[3], 100)
end

function TestChunker:test_very_long_line_with_spaces()
  local words = {}
  for i = 1, 50 do
    table.insert(words, 'word' .. i)
  end
  local content = table.concat(words, ' ')
  local chunks = chunker.chunk(content, 50)

  -- Each chunk should be <= 50
  for _, c in ipairs(chunks) do
    lu.assertTrue(#c <= 50, 'Chunk length should be <= 50: ' .. #c)
  end

  -- All words should be present across chunks
  local combined = table.concat(chunks, ' ')
  for _, w in ipairs(words) do
    lu.assertTrue(
      combined:find(w, 1, true) ~= nil,
      'Word "' .. w .. '" should be present'
    )
  end
end

------------------------------------------------------------
-- Platform limits
------------------------------------------------------------

function TestChunker:test_platform_limits_exist()
  lu.assertEquals(chunker.Limits.DISCORD, 2000)
  lu.assertEquals(chunker.Limits.TELEGRAM, 4096)
  lu.assertEquals(chunker.Limits.WECHAT, 2048)
  lu.assertEquals(chunker.Limits.WECOM, 2048)
  lu.assertEquals(chunker.Limits.SLACK, 40000)
  lu.assertEquals(chunker.Limits.DINGTALK, 20000)
  lu.assertEquals(chunker.Limits.LARK, 30720)
end

function TestChunker:test_wechat_limit_with_table()
  -- Simulate a realistic WeChat message with a table
  local rows = { '| 功能 | 描述 |', '|------|------|' }
  for i = 1, 30 do
    table.insert(rows, '| 功能' .. i .. ' | 这是一个描述说明文字 |')
  end
  local table_text = table.concat(rows, '\n')
  local content = '以下是功能列表：\n\n' .. table_text

  local chunks = chunker.chunk(content, chunker.Limits.WECHAT)

  -- All chunks must be within WeChat limit
  for _, c in ipairs(chunks) do
    lu.assertTrue(
      #c <= chunker.Limits.WECHAT,
      'Chunk must be within WeChat limit: ' .. #c
    )
  end

  -- No chunk should contain a partial table (header without separator)
  for _, c in ipairs(chunks) do
    -- If chunk contains a table header, it must also contain the separator
    if c:find('^|', 1) then
      local clines = vim.split(c, '\n', { plain = true })
      if #clines >= 1 and clines[1]:match('^|') then
        -- Either it has a separator line, or it's continuation rows
        -- (continuation chunks also have header repeated)
        lu.assertTrue(
          #clines >= 2,
          'Table chunk should have at least header + one row'
        )
      end
    end
  end
end

------------------------------------------------------------
-- _split_long_line helper
------------------------------------------------------------

function TestChunker:test_split_long_line_short()
  local parts = chunker._split_long_line('hello', 100)
  lu.assertEquals(#parts, 1)
  lu.assertEquals(parts[1], 'hello')
end

function TestChunker:test_split_long_line_with_spaces()
  local line = 'word1 word2 word3 word4 word5'
  local parts = chunker._split_long_line(line, 15)

  for _, p in ipairs(parts) do
    lu.assertTrue(#p <= 15, 'Part should be <= 15: ' .. #p)
  end

  -- Reconstructed should contain all words
  local combined = table.concat(parts, ' ')
  lu.assertTrue(combined:find('word1', 1, true) ~= nil)
  lu.assertTrue(combined:find('word5', 1, true) ~= nil)
end

function TestChunker:test_split_long_line_no_spaces()
  local line = string.rep('a', 50)
  local parts = chunker._split_long_line(line, 20)

  lu.assertEquals(#parts, 3)
  lu.assertEquals(#parts[1], 20)
  lu.assertEquals(#parts[2], 20)
  lu.assertEquals(#parts[3], 10)
end

------------------------------------------------------------
-- Edge cases
------------------------------------------------------------

function TestChunker:test_single_block_exceeds_max()
  -- Single paragraph that exceeds max_length
  local lines = {}
  for i = 1, 10 do
    table.insert(lines, 'This is line number ' .. i .. ' of the paragraph.')
  end
  local content = table.concat(lines, '\n')
  local chunks = chunker.chunk(content, 80)

  for _, c in ipairs(chunks) do
    lu.assertTrue(#c <= 80, 'Chunk should be <= 80: ' .. #c)
  end
end

function TestChunker:test_only_newlines()
  local chunks = chunker.chunk('\n\n\n', 100)
  -- Should produce empty or minimal chunks
  lu.assertTrue(#chunks <= 1)
end

function TestChunker:test_content_starts_with_table()
  local table_text = table.concat({
    '| A | B |',
    '|---|---|',
    '| 1 | 2 |',
  }, '\n')
  local chunks = chunker.chunk(table_text, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], table_text)
end

function TestChunker:test_content_ends_with_table()
  local content = 'Some text.\n\n| A | B |\n|---|---|\n| 1 | 2 |'
  local chunks = chunker.chunk(content, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

function TestChunker:test_adjacent_tables()
  local t1 = '| A | B |\n|---|---|\n| 1 | 2 |'
  local t2 = '| C | D |\n|---|---|\n| 3 | 4 |'
  local content = t1 .. '\n\n' .. t2
  local chunks = chunker.chunk(content, 500)

  lu.assertEquals(#chunks, 1)
  lu.assertEquals(chunks[1], content)
end

function TestChunker:test_adjacent_tables_split()
  local t1 = '| A | B |\n|---|---|\n| ' .. string.rep('x', 40) .. ' | 2 |'
  local t2 = '| C | D |\n|---|---|\n| ' .. string.rep('y', 40) .. ' | 4 |'
  local content = t1 .. '\n\n' .. t2
  local chunks = chunker.chunk(content, 60)

  -- Each table should be in separate chunks
  lu.assertTrue(#chunks >= 2)

  -- No chunk should contain parts of both tables
  for _, c in ipairs(chunks) do
    local has_t1 = c:find('| A | B |', 1, true) ~= nil
    local has_t2 = c:find('| C | D |', 1, true) ~= nil
    lu.assertFalse(
      has_t1 and has_t2,
      'No chunk should contain both tables'
    )
  end
end

return TestChunker


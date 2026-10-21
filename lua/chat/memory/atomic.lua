-- lua/chat/memory/atomic.lua
-- Shared atomic-write helper for memory stores.
--
-- Strategy: write the new data to a temp file first, then rename it
-- over the target. rename() replaces the target atomically, so
-- concurrent readers never observe a half-written file.
--
-- Windows caveat: when another process holds the target file open,
-- rename() fails (MoveFileEx cannot replace an open file). Direct
-- writes still succeed in that situation (fopen opens files in
-- shared mode), so on rename failure we fall back to a direct write
-- instead of silently dropping the new data.
--
-- Returns:
--   true  - data is persisted
--   false - data could not be persisted. When the temp file was
--           written but could neither be renamed nor copied, it is
--           intentionally kept on disk as a recovery artifact.
local M = {}

function M.atomic_write(path, content)
  local tmp_path = path .. '.tmp'

  -- Step 1: write the new data to a temp file
  local file = io.open(tmp_path, 'w')
  if not file then
    return false
  end
  file:write(content)
  file:close()

  -- Step 2: atomically replace the target
  if os.rename(tmp_path, path) then
    return true
  end

  -- Step 3: rename failed (e.g. target locked by another process on
  -- Windows); fall back to a direct write, which usually still works
  local direct = io.open(path, 'w')
  if not direct then
    return false -- keep .tmp for manual recovery
  end
  direct:write(content)
  direct:close()
  os.remove(tmp_path)
  return true
end

return M


-- lua/chat/windows/title.lua
-- Shared "pill" title rendering for the chat.nvim floating windows.
--
-- The prompt and the result window both render their title as a row of pills
-- welded into the top border:
--
--     ╭ openai | gpt ╮───╭ ~/project ╮───╭ discord ╮
--
-- Each pill is left badge + highlighted label + right badge, and the gap
-- between two pills repeats the floating window's own top border glyph, so the
-- pills read as embedded in the frame instead of floating above it.

local M = {}

local config = require('chat.config')

-- Decorative pill caps (powerline glyphs).
M.BADGE_LEFT = '\238\130\182'
M.BADGE_RIGHT = '\238\130\180'

-- Number of border glyphs drawn between two pills.
M.CONNECTOR_WIDTH = 3

-- Highlight of the connector. FloatBorder keeps it identical to the real
-- border, including any `winhighlight` remap (e.g. FloatBorder:WinSeparator).
M.CONNECTOR_HL = 'FloatBorder'

-- Top edge glyph of each built-in border style. `solid`, `shadow` and `none`
-- draw no top edge at all, so the connector stays blank for those.
local TOP_EDGE = {
  none = ' ',
  single = '─',
  double = '═',
  rounded = '─',
  solid = ' ',
  shadow = ' ',
}

--- Resolve the glyph the floating window's top border is drawn with, so the
--- pills can be joined by the very same line as the border. Supports both the
--- named styles and Neovim's 8-char border list, where index 2 is the top edge.
--- @return string glyph
function M.top_border_char()
  local border = config.config.border
  if type(border) == 'table' then
    return border[2] or '─'
  end
  return TOP_EDGE[border] or '─'
end

--- Wrap one label into a pill: left badge + highlighted text + right badge.
--- @param label string text, already padded with the spaces that fill the pill
--- @return table[] title chunks
function M.pill(label)
  local badge_hl = config.config.highlights.title_badge
  return {
    { M.BADGE_LEFT, badge_hl },
    { label, config.config.highlights.title },
    { M.BADGE_RIGHT, badge_hl },
  }
end

--- Build a pill row out of the given labels.
--- Declared as varargs on purpose: optional pills (cwd, integrations, usage)
--- arrive as trailing `nil`s, and a table with holes would silently drop
--- everything after the first gap under `ipairs` / `#`.
--- Blank labels are skipped instead of rendering an empty pill.
--- @param ... string|nil labels, already padded with surrounding spaces
--- @return table[] title chunks for vim.api.nvim_win_set_config
function M.build(...)
  local connector = M.top_border_char():rep(M.CONNECTOR_WIDTH)
  local chunks = {}
  for i = 1, select('#', ...) do
    local label = select(i, ...)
    if type(label) == 'string' and vim.trim(label) ~= '' then
      -- Insert the connector as one chunk: vim.list_extend with a bare
      -- {text, hl} pair would split it into two separate chunks.
      if #chunks > 0 then
        table.insert(chunks, { connector, M.CONNECTOR_HL })
      end
      vim.list_extend(chunks, M.pill(label))
    end
  end
  return chunks
end

return M


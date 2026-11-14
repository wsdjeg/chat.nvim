local spinners_theme = {
  frames = {
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  },
  strwidth = 1,
  timeout = 80,
}
local spinners = {}

--- Current spinner frame, or nil when the spinner is stopped.
--- Exposed so the window title can rebuild itself (session rename, token
--- refresh, ...) without dropping the animation: build_title reads it and
--- appends the frame to the session pill.
spinners.frame = nil

spinners.update = function(char)
  spinners.frame = char
  require('chat.windows').set_result_win_title(' chat.nvim ')
end

function spinners.start()
  if spinners.id then
    return
  end
  local index = 1
  spinners.update(spinners_theme.frames[index])
  spinners.id = vim.fn.timer_start(spinners_theme.timeout, function()
    if index < #spinners_theme.frames then
      index = index + 1
    else
      index = 1
    end

    spinners.update(spinners_theme.frames[index])
  end, { ['repeat'] = -1 })
end

function spinners.stop()
  pcall(vim.fn.timer_stop, spinners.id)
  spinners.id = nil
  spinners.frame = nil
  require('chat.windows').set_result_win_title(' chat.nvim ')
end

return spinners


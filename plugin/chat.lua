vim.api.nvim_create_user_command('Chat', function(opt)
  local windows = require('chat.windows')
  local sessions = require('chat.sessions')

  if #opt.fargs > 0 and opt.fargs[1] == 'new' then
    require('chat').open({
      session = sessions.new(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'prev' then
    require('chat').open({
      session = sessions.previous(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'next' then
    require('chat').open({
      session = sessions.next(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'delete' then
    require('chat').open({
      session = sessions.delete(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'bridge' then
    require('chat.integrations').set_session(
      opt.fargs[2],
      require('chat.windows').current_session()
    )
  elseif #opt.fargs > 0 and opt.fargs[1] == 'clear' then
    require('chat').open({
      redraw = sessions.clear(),
    })
  elseif #opt.fargs >= 2 and opt.fargs[1] == 'mcp' then
    local mcp = require('chat.mcp')
    local subcmd = opt.fargs[2]

    if subcmd == 'stop' then
      mcp.stop()
      require('chat.log').notify('MCP servers stopped')
    elseif subcmd == 'start' then
      mcp.connect()
      require('chat.log').notify('MCP servers starting')
    elseif subcmd == 'restart' then
      mcp.stop()
      vim.defer_fn(function()
        mcp.connect()
      end, 500)
      require('chat.log').notify('MCP servers restarting')
    end
  elseif #opt.fargs > 0 and opt.fargs[1] == 'cd' then
    if #opt.fargs >= 2 then
      local dir = vim.fs.normalize(vim.fn.fnamemodify(opt.fargs[2], ':p'))
      if vim.fn.isdirectory(dir) == 1 then
        require('chat').open({
          cwd = dir,
        })
      else
        require('chat.log').notify(
          string.format('%s is not valid directory', dir)
        )
      end
    else
      require('chat.log').notify(':Chat cd <directory>')
    end
  elseif #opt.fargs > 0 and opt.fargs[1] == 'save' then
    -- Save current session to file
    local current_session = windows.current_session()
    if not current_session then
      require('chat.log').notify('No active session to save', 'WarningMsg')
      return
    end
    if #opt.fargs >= 2 then
      sessions.save_to_file(current_session, opt.fargs[2])
    else
      require('chat.log').notify(':Chat save <filepath>')
    end
  elseif #opt.fargs > 0 and opt.fargs[1] == 'load' then
    -- Load session from file or URL
    if #opt.fargs >= 2 then
      local source = opt.fargs[2]
      local session_id

      -- Only treat as URL if it starts with http:// or https://
      if source:match('^https?://') then
        session_id = sessions.load_from_url(source)
      else
        session_id = sessions.load_from_file(source)
      end

      if session_id then
        require('chat').open({
          session = session_id,
        })
      end
    else
      require('chat.log').notify(':Chat load <filepath|url>')
    end
  elseif #opt.fargs > 0 and opt.fargs[1] == 'share' then
    -- Share current session to pastebin
    local current_session = windows.current_session()
    if not current_session then
      require('chat.log').notify('No active session to share', 'WarningMsg')
      return
    end
    sessions.share(current_session)
  elseif #opt.fargs > 0 and opt.fargs[1] == 'preview' then
    local current_session = require('chat.windows').current_session()
    if not current_session then
      require('chat.log').notify('No active session', 'WarningMsg')
      return
    end

    local config = require('chat.config')
    local url = string.format(
      'http://%s:%d/session?id=%s',
      config.config.http.host,
      config.config.http.port,
      current_session
    )

    -- Open in browser
    if vim.fn.has('win32') == 1 then
      vim.fn.system('start "" "' .. url .. '"')
    elseif vim.fn.has('mac') == 1 then
      vim.fn.system('open "' .. url .. '"')
    else
      vim.fn.system('xdg-open "' .. url .. '"')
    end

    require('chat.log').notify('Opening preview: ' .. url)
  else
    require('chat').open()
  end
end, {
  nargs = '*',
  complete = function(arglead, cmdline, pos)
    local pre_cursor = string.sub(cmdline, 1, pos)

    -- File path completion for save/load
    if pre_cursor:match('^Chat save ') then
      local path_arg = pre_cursor:match('^Chat save%s+(.*)$')
      return vim.fn.getcompletion(path_arg or '', 'file')
    end

    if pre_cursor:match('^Chat load ') then
      local path_arg = pre_cursor:match('^Chat load%s+(.*)$')
      return vim.fn.getcompletion(path_arg or '', 'file')
    end

    if pre_cursor:match('^Chat bridge ') then
      return vim.tbl_filter(
        function(t)
          return t ~= 'init' and vim.startswith(t, arglead)
        end,
        vim.tbl_map(
          function(t)
            return vim.fn.fnamemodify(t, ':t:r')
          end,
          vim.api.nvim_get_runtime_file('lua/chat/integrations/*.lua', true)
        )
      )
    end

    if pre_cursor:match('^Chat cd ') then
      local path_arg = pre_cursor:match('^Chat cd%s+(.*)$')
      return vim.fn.getcompletion(path_arg or '', 'dir')
    end
    if pre_cursor:match('^Chat mcp ') then
      -- MCP Subcommand completion
      return vim.tbl_filter(function(t)
        return vim.startswith(t, arglead)
      end, {
        'stop',
        'start',
        'restart',
      })
    end

    -- Subcommand completion
    return vim.tbl_filter(function(t)
      return vim.startswith(t, arglead)
    end, {
      'new',
      'prev',
      'next',
      'delete',
      'cd',
      'clear',
      'save',
      'load',
      'share',
      'mcp',
      'preview',
      'bridge',
    })
  end,
})

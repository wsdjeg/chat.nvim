vim.api.nvim_create_user_command('Chat', function(opt)
  --- Chat 命令使用的逻辑后期要更新，暂时未增加外逻辑
  --- 仅仅支持使用 `:Chat new` 打开新的 session
  -- ✅ 推荐结构（现在就打好地基）
  --
  -- 我建议你直接定一个规范：
  --
  -- :Chat <subcommand> [options...]
  --
  --
  -- 比如：
  --
  -- :Chat new
  -- :Chat new --name test
  -- :Chat open
  if #opt.fargs > 0 and opt.fargs[1] == 'new' then
    require('chat').open({
      session = require('chat.sessions').new(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'prev' then
    require('chat').open({
      session = require('chat.sessions').previous(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'next' then
    require('chat').open({
      session = require('chat.sessions').next(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'delete' then
    require('chat').open({
      session = require('chat.sessions').delete(),
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'cd' then
    if #opt.fargs >= 2 then
      local dir = vim.fn.fnamemodify(opt.fargs[2], ':p')
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
  else
    require('chat').open()
  end
end, {
  nargs = '*',
  complete = function(arglead, cmdline, pos)
    local pre_cursor = string.sub(cmdline, 1, pos)

    if pre_cursor:match('^Chat cd ') then
      local path_arg = string.match(pre_cursor, '^Chat cd%s+(.*)$')

      if path_arg then
        return vim.fn.getcompletion(path_arg, 'dir')
      else
        return vim.fn.getcompletion('', 'dir')
      end
    end

    return vim.tbl_filter(function(t)
      return vim.startswith(t, arglead)
    end, { 'new', 'prev', 'next', 'delete', 'cd' })
  end,
})

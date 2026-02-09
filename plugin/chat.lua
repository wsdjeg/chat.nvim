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
      session = require('chat.sessions').previous()
    })
  elseif #opt.fargs > 0 and opt.fargs[1] == 'next' then
    require('chat').open({
      session = require('chat.sessions').next()
    })
  else
    require('chat').open()
  end
end, { nargs = '*' })

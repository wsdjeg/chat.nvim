-- lua/chat/skills/setup-nvim-plugin-test.lua
-- /setup-nvim-plugin-test - Generate a user message that asks the LLM to
-- scaffold a Neovim plugin test system, referencing wsdjeg/chat.nvim's
-- test infrastructure via GitHub raw URLs.
--
-- Usage:
--   /setup-nvim-plugin-test

return {
  name = 'setup-nvim-plugin-test',
  description = 'Set up Neovim plugin test system (references wsdjeg/chat.nvim)',
  handler = function(_, _)
    local lines = {
      '请为当前项目搭建 Neovim 插件测试系统。',
      '',
      '参考 wsdjeg/chat.nvim 仓库的测试基础设施，以下是相关文件的 GitHub raw 链接，',
      '请先 fetch 这些链接获取具体内容，然后根据当前项目的实际情况生成对应的测试文件：',
      '',
      '## 参考文件',
      '',
      '1. **Makefile** (测试入口、依赖安装、PATTERN 过滤)',
      '   https://raw.githubusercontent.com/wsdjeg/chat.nvim/master/Makefile',
      '',
      '2. **test/minimal_init.lua** (headless 测试最小配置)',
      '   https://raw.githubusercontent.com/wsdjeg/chat.nvim/master/test/minimal_init.lua',
      '',
      '3. **test/run.lua** (luaunit 测试运行器)',
      '   https://raw.githubusercontent.com/wsdjeg/chat.nvim/master/test/run.lua',
      '',
      '4. **test/install_deps.lua** (跨平台依赖安装器)',
      '   https://raw.githubusercontent.com/wsdjeg/chat.nvim/master/test/install_deps.lua',
      '',
      '## 要求',
      '',
      '- 使用 luaunit 作为测试框架',
      '- Makefile 支持 `make test`、`make test PATTERN=xxx`、`make install-deps`、`make clean`',
      '- test/minimal_init.lua 中需要根据当前项目的模块名加载插件',
      '- test/run.lua 需支持 PATTERN 过滤、自动发现 `test/**/*_spec.lua`',
      '- test/install_deps.lua 需跨平台（curl / powershell / wget fallback）',
      '- 生成一个 `test/example_spec.lua` 示例测试文件',
      '- 先读取当前项目结构，确保生成的文件与项目实际模块名和结构匹配',
      '- 如果已有同名文件则跳过，不要覆盖',
    }

    return {
      content = table.concat(lines, '\n'),
      role = 'user',
      request = true,
    }
  end,
}


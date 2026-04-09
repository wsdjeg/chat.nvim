
---
layout: default
title: Quick Start
nav_order: 1
---

# Quick Start

{: .no_toc }

Get up and running with chat.nvim in 5 minutes!

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

## 1. Install Plugin

Add to your plugin manager:

```lua
-- lazy.nvim
{
  'wsdjeg/chat.nvim',
  dependencies = { 'wsdjeg/job.nvim' },
}
```

```vim
" nvim-plug
Plug 'wsdjeg/job.nvim'
Plug 'wsdjeg/chat.nvim'
```

---

## 2. Configure API Key

Add at least one AI provider key to your Neovim config:

```lua
require('chat').setup({
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',  -- or openai, github, etc.
  },
  allowed_path = {
    vim.fn.getcwd(),
  },
})
```

> 💡 **Tip:** Get your API key from [DeepSeek](https://platform.deepseek.com/) or [OpenAI](https://platform.openai.com/)

---

## 3. Start Chatting

Open Neovim and run:

```vim
:Chat
```

Then start chatting with AI! Try asking:

```
Explain the code in the current buffer
```

---

## 4. Basic Commands

| Command | Description |
|---------|-------------|
| `:Chat` | Open chat window |
| `:Chat new` | Start new session |
| `:Chat prev` / `:Chat next` | Switch sessions |
| `:Chat close` | Close chat window |

---

## 5. Try Tools

Use tools by prefixing with `@`:

```
@read_file ./src/main.lua
@git_status
@search_text pattern="function"
```

---

## What's Next?

- 📖 [Configuration](configuration.md) - Customize settings
- 🛠️ [Tools](usage/tools.md) - Explore available tools
- 🧠 [Memory](usage/memory.md) - Learn about memory system
- 🔌 [Providers](usage/providers.md) - Configure AI providers

---

## Need Help?

- [Full Documentation](https://nvim.chat/documentation/)
- [GitHub Issues](https://github.com/wsdjeg/chat.nvim/issues)
- [Discord Community](https://discord.gg/your-invite)


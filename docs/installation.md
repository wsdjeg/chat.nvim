---
layout: default
title: Installation
nav_order: 1
parent: Getting Started
---

# Installation

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

## Prerequisites

### System Dependencies

Optional but recommended for full functionality:

- **ripgrep (rg)**: Required for the `@search_text` tool
- **curl**: Required for the `@fetch_web` tool
- **git**: Required for the `@git_diff` tool

Install with your package manager:

```bash
# Ubuntu/Debian
sudo apt install ripgrep curl git

# macOS
brew install ripgrep curl git

# Arch Linux
sudo pacman -S ripgrep curl git
```

### Neovim Plugin Dependencies

- **job.nvim**: Required dependency for asynchronous operations
- **picker.nvim**: Optional but recommended for enhanced session management

---

## Package Manager Installation

### Using lazy.nvim

```lua
{
  'wsdjeg/chat.nvim',
  dependencies = {
    'wsdjeg/job.nvim', -- Required
    'wsdjeg/picker.nvim', -- Optional but recommended
  },
}
```

### Using nvim-plug

```lua
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    depends = {
      'wsdjeg/job.nvim',
      'wsdjeg/picker.nvim',
    },
  },
})
```

### Using packer.nvim

```lua
use({
  'wsdjeg/chat.nvim',
  requires = {
    'wsdjeg/job.nvim',
    'wsdjeg/picker.nvim',
  },
})
```

---

## Manual Installation

If you're not using a package manager:

1. Clone the repositories:

   ```bash
   git clone https://github.com/wsdjeg/chat.nvim ~/.local/share/nvim/site/pack/chat/start/chat.nvim
   git clone https://github.com/wsdjeg/job.nvim ~/.local/share/nvim/site/pack/chat/start/job.nvim
   ```

2. Add to your Neovim configuration:

   ```lua
   vim.cmd[[packadd job.nvim]]
   vim.cmd[[packadd chat.nvim]]
   require('chat').setup({
     -- Your configuration here
   })
   ```

---

## Post-Installation Setup

### 1. Configure API Keys

Configure at least one AI provider API key:

```lua
require('chat').setup({
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
    github = 'github_pat_xxxxxxxx',
    openai = 'sk-xxxxxxxxxxxx',
  },
})
```

### 2. Set File Access Control

Configure which directories tools can access:

```lua
require('chat').setup({
  allowed_path = {
    vim.fn.getcwd(), -- Current working directory
    vim.fn.expand('~/.config/nvim'), -- Neovim config
  },
})
```

### 3. Enable Memory System (Optional)

```lua
require('chat').setup({
  memory = {
    enable = true,
    long_term = {
      max_memories = 500,
      retrieval_limit = 3,
    },
  },
})
```

---

## Quick Start

After installation, you can immediately start using chat.nvim:

```vim
:Chat          " Open chat window
:Chat new      " Start a new session
:Chat prev     " Switch to previous session
:Chat next     " Switch to next session
```

---

## Troubleshooting

### Common Issues

**Plugin not loading:**
- Ensure `job.nvim` is installed and loaded before `chat.nvim`
- Check your Neovim version (requires Neovim 0.9+)

**API key errors:**
- Verify your API keys are correct
- Ensure the provider name matches the key in configuration

**Tool access errors:**
- Verify `allowed_path` is set correctly
- Ensure the path exists and is accessible

For more issues, visit the [GitHub Issues](https://github.com/wsdjeg/chat.nvim/issues) page.


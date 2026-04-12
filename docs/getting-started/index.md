---
layout: default
title: Getting Started
nav_order: 2
has_children: true
---

<!-- prettier-ignore-start -->
# Getting Started
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

Welcome to chat.nvim! This guide will help you get started with the plugin.

## Overview

chat.nvim is a lightweight, extensible chat plugin for Neovim with AI integration. It allows you to:

- Chat with AI assistants directly in your editor
- Manage multiple parallel sessions with different models
- Use built-in tools for file operations, Git, web search, etc.
- Integrate with instant messaging platforms for remote access

---
## Quick Links

- [Installation](./installation/) - Install and configure chat.nvim
- [Configuration](../configuration/) - Customize settings and options
- [Usage](../usage/) - Commands, keybindings, and workflows

---

## Prerequisites

Before installing chat.nvim, ensure you have:

1. **Neovim 0.9+** - Required for modern Lua features
2. **job.nvim** - Required dependency for async operations
3. **picker.nvim** - Optional but recommended for enhanced UI
4. **System tools** (optional): ripgrep, curl, git for full tool functionality

---

## First Steps

### 1. Install the Plugin

Follow the [Installation Guide](./installation/) for your package manager.

### 2. Configure API Keys

Set up API keys for your preferred AI providers:

```lua
require('chat').setup({
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
    openai = 'sk-xxxxxxxxxxxx',
  },
})
```

### 3. Start Chatting

Open the chat window and start your first conversation:

```vim
:Chat
```

---

## Next Steps

After getting started, explore:

- [Providers](../providers/) - Configure different AI providers
- [Tools](../tools/) - Learn about available tools
- [Memory System](../memory/) - Understand the memory architecture
- [IM Integration](../integrations/im/) - Connect messaging platforms

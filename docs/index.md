---
layout: default
title: Home
nav_order: 0
---

<p class="fs-9">A lightweight, extensible chat plugin for Neovim with AI integration.</p>

<p class="fs-6 fw-300">Chat with AI assistants directly in your editor using a clean, floating window interface.</p>

<p>
  <a href="https://github.com/wsdjeg/chat.nvim" class="btn fs-5 mb-4 mb-md-0">View on GitHub</a>
  <a href="https://github.com/wsdjeg/chat.nvim/releases" class="btn fs-5 mb-4 mb-md-0">Releases</a>
</p>

---

## ✨ Key Features

<div class="feature-grid">
  <div class="feature-card">
    <h3>🧠 Three-Tier Memory</h3>
    <p>Working, daily, and long-term memory system with automatic extraction and priority-based retrieval.</p>
  </div>
  
  <div class="feature-card">
    <h3>🔄 Parallel Sessions</h3>
    <p>Run multiple conversations with different AI models, each maintaining separate context and settings.</p>
  </div>
  
  <div class="feature-card">
    <h3>🤖 16+ AI Providers</h3>
    <p>Built-in support for DeepSeek, OpenAI, Anthropic, GitHub AI, Gemini, Ollama, and many more AI services.</p>
  </div>
  
  <div class="feature-card">
    <h3>🛠️ 20+ Built-in Tools</h3>
    <p>File operations, Git integration, web search, memory management, planning, and extensible custom tools.</p>
  </div>
  
  <div class="feature-card">
    <h3>🔌 MCP Protocol</h3>
    <p>Native Model Context Protocol support for extended tool capabilities via stdio and HTTP transports.</p>
  </div>
  
  <div class="feature-card">
    <h3>💬 IM Integration</h3>
    <p>Connect Discord, Telegram, Slack, Lark, DingTalk, WeCom, and WeChat for remote AI interaction.</p>
  </div>
  
  <div class="feature-card">
    <h3>🌐 HTTP API</h3>
    <p>Built-in HTTP server for receiving external messages with API key authentication.</p>
  </div>
  
  <div class="feature-card">
    <h3>📝 Zettelkasten</h3>
    <p>Note-taking support via zettelkasten.nvim integration for knowledge management.</p>
  </div>
  
  <div class="feature-card">
    <h3>🔍 Picker Integration</h3>
    <p>Seamless integration with picker.nvim for browsing history and switching providers/models.</p>
  </div>
  
  <div class="feature-card">
    <h3>⚡ Streaming Responses</h3>
    <p>Real-time AI responses with cancellation support and token usage tracking.</p>
  </div>
</div>

---

## 🚀 Quick Start

### Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'wsdjeg/chat.nvim',
  dependencies = {
    'wsdjeg/job.nvim', -- Required
    'wsdjeg/picker.nvim', -- Optional but recommended
  },
}
```

Using [nvim-plug](https://github.com/junegunn/vim-plug):

```lua
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    depends = {
      'wsdjeg/job.nvim', -- Required
      'wsdjeg/picker.nvim', -- Optional but recommended
    },
  },
})
```

---

## 📚 Documentation

### Getting Started

- [Quick Start](/docs/quick-start/) - Get up and running in 5 minutes
- [Installation](/docs/installation/) - Detailed setup and prerequisites
- [Configuration](/docs/configuration/) - Customize chat.nvim settings

### Usage Guide

- [Overview](/docs/usage/) - Commands, keybindings, and workflows
- [AI Providers](/docs/usage/providers/) - Configure AI providers (DeepSeek, OpenAI, Anthropic, etc.)
- [Tools](/docs/usage/tools/) - Built-in tools (file operations, Git, web search, etc.)
- [Memory System](/docs/usage/memory/) - Three-tier memory architecture
- [MCP](/docs/usage/mcp/) - Model Context Protocol integration

### Integrations

- [Overview](/docs/integrations/im/) - Messaging platform integrations
- [Discord](/docs/integrations/discord/) - Discord bot integration
- [Telegram](/docs/integrations/telegram/) - Telegram bot integration
- [Slack](/docs/integrations/slack/) - Slack bot integration
- [Lark](/docs/integrations/lark/) - Lark (Feishu) bot integration
- [DingTalk](/docs/integrations/dingtalk/) - DingTalk bot integration
- [WeCom](/docs/integrations/wecom/) - WeCom (Enterprise WeChat) integration
- [Weixin](/docs/integrations/weixin/) - WeChat integration

### API

- [Overview](/docs/api/) - External integration options
- [HTTP API](/docs/api/http/) - Receive messages via HTTP endpoints
- [Memory System](/docs/memory/) - Three-tier memory architecture
- [MCP](/docs/mcp/) - Model Context Protocol integration

### Using chat.nvim

- [Providers](/docs/providers/) - Configure AI providers (DeepSeek, OpenAI, Anthropic, etc.)
- [Tools](/docs/tools/) - Explore built-in tools (file operations, Git, web search, etc.)
- [Memory System](/docs/memory/) - Three-tier memory architecture
- [MCP](/docs/mcp/) - Model Context Protocol integration

### Integrations

- [Overview](/docs/integrations/im/) - Messaging platform integrations
- [Discord](/docs/integrations/discord/) - Discord bot integration
- [Telegram](/docs/integrations/telegram/) - Telegram bot integration
- [Slack](/docs/integrations/slack/) - Slack bot integration
- [Lark](/docs/integrations/lark/) - Lark (Feishu) bot integration
- [DingTalk](/docs/integrations/dingtalk/) - DingTalk bot integration
- [WeCom](/docs/integrations/wecom/) - WeCom (Enterprise WeChat) integration
- [Weixin](/docs/integrations/weixin/) - WeChat integration

### API

- [Overview](/docs/api/) - External integration options
- [HTTP API](/docs/api/http/) - Receive messages via HTTP endpoints

## 💬 Community

- **GitHub**: [wsdjeg/chat.nvim](https://github.com/wsdjeg/chat.nvim)
- **Issues**: [Report bugs or request features](https://github.com/wsdjeg/chat.nvim/issues)
- **Author**: [wsdjeg](https://wsdjeg.net/)

---

## 📄 License

chat.nvim is released under the [GPL-3.0 License](https://github.com/wsdjeg/chat.nvim/blob/master/LICENSE).

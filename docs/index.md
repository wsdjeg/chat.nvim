---
layout: default
title: Home
nav_order: 1
---

# chat.nvim

<p class="fs-9">A lightweight, extensible chat plugin for Neovim with AI integration.</p>

<p class="fs-6 fw-300">Chat with AI assistants directly in your editor using a clean, floating window interface.</p>

<p>
  <a href="https://github.com/wsdjeg/chat.nvim" class="btn fs-5 mb-4 mb-md-0">View on GitHub</a>
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
    <p>Built-in support for DeepSeek, OpenAI, Anthropic, GitHub AI, and many more AI services.</p>
  </div>
  
  <div class="feature-card">
    <h3>🛠️ 20+ Tools</h3>
    <p>File operations, Git integration, web search, memory management, and extensible custom tools.</p>
  </div>
  
  <div class="feature-card">
    <h3>🔌 MCP Protocol</h3>
    <p>Native Model Context Protocol support for extended tool capabilities.</p>
  </div>
  
  <div class="feature-card">
    <h3>💬 IM Integration</h3>
    <p>Connect Discord, Telegram, Lark, DingTalk, WeCom, and WeChat for remote AI interaction.</p>
  </div>
</div>

---

## 🚀 Quick Start

### Installation

Using [nvim-plug](https://github.com/junegunn/vim-plug)

```lua
require('plug').add({
  {
    'wsdjeg/chat.nvim',
    depends = {
      {
        'wsdjeg/job.nvim', -- Required
        'wsdjeg/picker.nvim', -- Optional but recommended
      },
    },
  },
})
```

## 💬 Community

- **GitHub**: [wsdjeg/chat.nvim](https://github.com/wsdjeg/chat.nvim)
- **Issues**: [Report bugs or request features](https://github.com/wsdjeg/chat.nvim/issues)
- **Author**: [wsdjeg](https://wsdjeg.net/)

---

## 📄 License

chat.nvim is released under the [GPL-3.0 License](https://github.com/wsdjeg/chat.nvim/blob/master/LICENSE).

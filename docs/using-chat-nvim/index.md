---
layout: default
title: Using chat.nvim
nav_order: 6
has_children: true
---

# Using chat.nvim

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

Learn how to use chat.nvim's advanced features for enhanced productivity.

## Overview

chat.nvim provides powerful features beyond basic chatting:

- **Memory System**: Three-tier memory for context retention
- **MCP Protocol**: Extended tool capabilities via external servers
- **Tools**: 20+ built-in tools for file operations, Git, web search, etc.

---

## Features

### Memory System

chat.nvim implements a sophisticated three-tier memory system:

- **Working Memory** ⚡ - Session-scoped, highest priority
- **Daily Memory** 📅 - Temporary, auto-expires after 7-30 days
- **Long-term Memory** 💾 - Permanent knowledge storage

Learn more: [Memory System](/docs/memory/)

### MCP (Model Context Protocol)

Native MCP support for extended tool capabilities:

- Connect to MCP servers via stdio or HTTP
- Automatically discover MCP tools
- Seamlessly integrate with built-in tools

Learn more: [MCP](/docs/mcp/)

### Built-in Tools

20+ built-in tools for various operations:

- File: `read_file`, `write_file`, `find_files`, `search_text`
- Git: `git_add`, `git_commit`, `git_diff`, `git_log`, etc.
- Web: `fetch_web`, `web_search`
- Memory: `extract_memory`, `recall_memory`
- Planning: `plan`

Learn more: [Tools](/docs/tools/)

---

## Quick Links

- [Memory System](/docs/memory/) - Three-tier memory architecture
- [MCP](/docs/mcp/) - Model Context Protocol integration

---

## Next Steps

- [Tools Documentation](/docs/tools/) - Detailed tool usage
- [HTTP API](/docs/api/) - External integration
- [IM Integration](/docs/integrations/im/) - Messaging platforms

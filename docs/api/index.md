---
layout: default
title: API
nav_order: 7
has_children: true
---

<!-- prettier-ignore-start -->
# API
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

chat.nvim provides APIs for external integration and automation.

## Overview

chat.nvim offers HTTP API for external applications to interact with your chat sessions:

- **HTTP Server**: Built-in server for receiving messages
- **Session Management**: List and preview sessions via API
- **External Integration**: Connect scripts, CI/CD, monitoring tools

---
### Endpoints

| Endpoint    | Method | Description                         |
| ----------- | ------ | ----------------------------------- |
| `/`         | POST   | Send message to a session           |
| `/sessions` | GET    | Get session list with details       |
| `/session`  | GET    | Get HTML preview of a session       |
### Endpoints

| Endpoint    | Method | Description                    |
| ----------- | ------ | ------------------------------ |
| `/`         | POST   | Send message to a session      |
| `/sessions` | GET    | Get list of active session IDs |
| `/session`  | GET    | Get HTML preview of a session  |

### Example

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "my-session", "content": "Hello from curl!"}'
```

Learn more: [HTTP API](./http/)

---

## Building Applications

The HTTP API enables you to build applications on top of chat.nvim. You can create custom integrations, bots, or standalone tools that leverage AI capabilities.

### Example: Nova

[Nova](https://github.com/wsdjeg/Nova) is an AI assistant built on chat.nvim's HTTP API. It demonstrates how to:

- **Integrate with chat.nvim**: Use the HTTP API to communicate with chat sessions
- **Build custom UI**: Create your own interface for AI interactions
- **Extend functionality**: Add features specific to your use case

```bash
# Example: Using Nova with chat.nvim
# Nova sends requests to chat.nvim HTTP server
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "nova", "content": "Help me with this code"}'
```

### Getting Started

1. **Enable HTTP API**: Configure `api.enabled = true` in your chat.nvim setup
2. **Set API Key**: Configure `api.api_key` for authentication
3. **Choose Port**: Default is `7777`, configurable via `api.port`
4. **Build Your App**: Use any HTTP client to interact with the API

See [HTTP API](./http/) for complete API reference.

---

## Quick Links

- [HTTP API](./http/) - Complete HTTP API documentation

---

## Next Steps

- [HTTP API](./http/) - HTTP API integration
- [IM Integration](../integrations/im/) - Messaging platforms

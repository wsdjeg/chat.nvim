---
layout: default
title: Overview
nav_order: 0
parent: API
---

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

chat.nvim provides APIs for external integration and automation.

## Overview

chat.nvim offers HTTP API for external applications to interact with your chat sessions:

- **HTTP Server**: Built-in server for receiving messages
- **Session Management**: List and preview sessions via API
- **External Integration**: Connect scripts, CI/CD, monitoring tools

---

## HTTP API

The HTTP API allows external applications to send messages to chat.nvim:

### Endpoints

| Endpoint    | Method | Description                          |
| ----------- | ------ | ------------------------------------ |
| `/`         | POST   | Send message to a session            |
| `/sessions` | GET    | Get list of active session IDs       |
| `/session`  | GET    | Get HTML preview of a session        |

### Example

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "my-session", "content": "Hello from curl!"}'
```

Learn more: [HTTP API](/docs/api/http/)

---

## Quick Links

- [HTTP API](/docs/api/http/) - Complete HTTP API documentation

---

## Next Steps

- [HTTP API](/docs/api/http/) - HTTP API integration
- [IM Integration](/docs/integrations/im/) - Messaging platforms

---
layout: default
title: HTTP API
parent: API
nav_order: 1
---

<!-- prettier-ignore-start -->
# HTTP API
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

chat.nvim includes a built-in HTTP server built on libuv TCP, allowing external applications to interact with chat sessions. This enables integration with CLI tools, CI/CD pipelines, web applications, and more.

---

## Enabling the HTTP Server

The HTTP server is automatically started when `http.api_key` is set to a non-empty value:

```lua
require('chat').setup({
  -- ... other configuration
  http = {
    host = '127.0.0.1',  -- Default: '127.0.0.1'
    port = 7777,          -- Default: 7777
    api_key = 'your-secret-key',  -- Required to enable server
  },
})
```

**Base URL**: `http://{host}:{port}`

**Authentication**: All requests except `GET /session` (HTML preview) require the `X-API-Key` header.

---

## Endpoints Overview

| Endpoint | Method | Description |
|---|---|---|
| `/` | POST | Push a message to a session's message queue |
| `/sessions` | GET | List all sessions with details |
| `/sessions/{id}` | GET | Get a single session's details |
| `/sessions/{id}/raw` | GET | Get a session's raw cache JSON |
| `/providers` | GET | List all available providers and their models |
| `/skills` | GET | List all registered skills (slash commands) |
| `/messages` | GET | Get messages for a session |
| `/session/new` | POST | Create a new session |
| `/session/{id}` | DELETE | Delete a session |
| `/session/{id}/stop` | POST | Stop generation |
| `/session/{id}/clear` | POST | Clear all messages in a session |
| `/session/{id}/retry` | POST | Retry the last message |
| `/session/{id}/messages/{index}` | DELETE | Delete a specific message |
| `/session/{id}/provider` | PUT | Set the provider for a session |
| `/session/{id}/model` | PUT | Set the model for a session |
| `/session/{id}/cwd` | PUT | Set the working directory for a session |
| `/session/{id}/upload-dir` | GET | Get the upload directory for a session |
| `/session/{id}/upload-dir` | PUT | Set the upload directory for a session |
| `/session/{id}/pin` | PUT | Set the pin status for a session |
| `/session/{id}/title` | PUT | Set the title for a session |
| `/session/{id}/upload` | POST | Upload a file to the session's upload directory (or cwd) |
| `/session/{id}/bridge` | GET | List all bridged integrations for a session |
| `/session/{id}/bridge/{platform}` | PUT | Bridge an integration to a session |
| `/session/{id}/bridge/{platform}` | DELETE | Unbridge a specific integration from a session |
| `/session/{id}/bridge` | DELETE | Unbridge all integrations from a session |
| `/session` | GET | Get HTML preview of a session (no auth required) |
| `/weixin/login/status` | GET | Poll WeChat login status (auto-starts login flow) |
| `/weixin/credentials` | DELETE | Logout WeChat (stop polling, clear all credentials) |

---

## Endpoint Details

### POST `/`

Push a message to a session's message queue. The message will be delivered once the session is idle.

**Request Body:**

```json
{
  "session": "2024-01-15-10-30-00",
  "content": "Hello from external app!"
}
```

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `session` | string | Yes | Target session ID |
| `content` | string | Yes | Message content |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - message queued |
| 400 | Invalid JSON body or missing required fields |
| 401 | Invalid or missing API key |

**Example:**

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "What is the weather today?"}'
```

---

### GET `/sessions`

Get a list of all sessions with details.

**Response (200 OK):**

```json
[
  {
    "id": "2024-01-15-10-30-00",
    "title": "Help me write a Lua plugin...",
    "cwd": "/home/user/project",
    "provider": "openai",
    "model": "gpt-4o",
    "pin": false,
    "in_progress": false,
    "message_count": 5,
    "last_message": {
      "role": "assistant",
      "content": "I'd be happy to help you write a Lua plugin for Neovim. Let's start by...",
      "created": 1705315800
    },
    "cleared_at": null
  }
]
```

**Response Fields:**

| Field | Type | Description |
|---|---|---|
| `id` | string | Session ID (format: `YYYY-MM-DD-HH-MM-SS`) |
| `title` | string | Session title (auto-extracted from first user message, max 50 chars) |
| `cwd` | string | Session working directory |
| `provider` | string | Provider name |
| `model` | string | Model name |
| `pin` | boolean | Whether the session is pinned |
| `in_progress` | boolean | Whether generation is in progress |
| `message_count` | number | Total number of messages |
| `last_message` | object\|null | Last message object (null if no messages) |
| `cleared_at` | number\|null | Unix timestamp when session was last cleared (null if never cleared) |

**`last_message` Object:**

| Field | Type | Description |
|---|---|---|
| `role` | string | Message role (`user` / `assistant`) |
| `content` | string | Message content (truncated to 100 chars) |
| `created` | number | Unix timestamp of message creation |

**Example:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

---

### GET `/sessions/{id}`

Get details for a single session.

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |

**Response (200 OK):**

Same format as a single element in the `GET /sessions` response.

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success |
| 404 | Session not found |

**Example:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions/2024-01-15-10-30-00
```

---

### GET `/sessions/{id}/raw`

Get the raw cache JSON content for a session. Includes all messages, metadata, usage statistics, and complete session state.

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success - returns raw JSON content |
| 404 | Cache file not found |
| 500 | Failed to read cache file |

**Example:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions/2024-01-15-10-30-00/raw
```

---

### GET `/providers`

Get all registered providers and their available models.

**Response (200 OK):**

```json
[
  {
    "name": "anthropic",
    "models": ["claude-3-5-sonnet-20241022", "claude-3-opus-20240229"]
  },
  {
    "name": "deepseek",
    "models": ["deepseek-v4-pro", "deepseek-v4-flash"]
  },
  {
    "name": "openai",
    "models": ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
  }
]
```

**Response Fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Provider name (e.g., `openai`, `anthropic`) |
| `models` | string[] | List of available models (from `available_models()`) |

**Example:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers
```

---

### GET `/skills`

Get all registered skills (slash commands available in the prompt window).

**Response (200 OK):**

```json
[
  {
    "name": "clear",
    "description": "Clear all messages in current session",
    "builtin": true
  },
  {
    "name": "help",
    "description": "Show available skills",
    "builtin": true
  },
  {
    "name": "model",
    "description": "Switch model (e.g. /model gpt-4o)",
    "builtin": true
  },
  {
    "name": "my-skill",
    "description": "Custom user skill",
    "builtin": false
  }
]
```

**Response Fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Skill name (invoke with `/name` in the prompt window) |
| `description` | string | Short description shown in `/help` |
| `builtin` | boolean | `true` for built-in skills, `false` for user skills |

**Example:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/skills
```

---

### GET `/messages`

Get the message list for a specific session, with optional pagination.

**Query Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `session` | string | Yes | Session ID |
| `since` | number | No | Starting index (1-indexed) |

**Response (200 OK):**

```json
[
  {
    "role": "user",
    "content": "Hello!"
  },
  {
    "role": "assistant",
    "content": "Hi there! How can I help you?",
    "reasoning_content": "The user is greeting me...",
    "tool_calls": null,
    "tool_call_id": null,
    "created": 1705315800,
    "usage": {
      "total_tokens": 50,
      "prompt_tokens": 20,
      "completion_tokens": 30
    },
    "error": null,
    "tool_call_state": null
  }
]
```

**Message Object Fields:**

| Field | Type | Description |
|---|---|---|
| `role` | string | Role: `user` / `assistant` / `tool` / `system` |
| `content` | string\|null | Message content (may be null for tool calls) |
| `reasoning_content` | string\|null | Reasoning content (for thinking models) |
| `tool_calls` | array\|null | Tool calls made by assistant |
| `tool_call_id` | string\|null | Tool call ID (for tool role messages) |
| `created` | number\|null | Unix timestamp |
| `usage` | object\|null | Token usage statistics (`total_tokens`, `prompt_tokens`, `completion_tokens`) |
| `error` | string\|null | Error message if request failed |
| `tool_call_state` | string\|null | Tool call execution state |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success |
| 400 | Missing `session` parameter |
| 404 | Session not found |

**Examples:**

```bash
# Get all messages
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"

# Get messages starting from index 5
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00&since=5" \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/new`

Create a new session, optionally specifying the provider and model.

**Request Body** (optional):

```json
{
  "provider": "openai",
  "model": "gpt-4o"
}
```

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `provider` | string | No | Provider to use |
| `model` | string | No | Model to use |

**Response (200 OK):**

```json
{
  "id": "2024-01-15-10-30-00",
  "title": "",
  "cwd": "/home/user/project",
  "provider": "openai",
  "model": "gpt-4o",
  "in_progress": false,
  "message_count": 0,
  "last_message": null
}
```

**Response Fields:**

| Field | Type | Description |
|---|---|---|
| `id` | string | Newly created session ID |
| `title` | string | Session title (empty for new sessions) |
| `cwd` | string | Current working directory |
| `provider` | string | Provider name |
| `model` | string | Model name |
| `in_progress` | boolean | Generation status (false for new sessions) |
| `message_count` | number | Message count (0 for new sessions) |
| `last_message` | null | Last message (null for new sessions) |

**Examples:**

```bash
# Create session with default provider/model
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key"

# Create session with custom provider/model
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "openai", "model": "gpt-4o"}'
```

---

### DELETE `/session/{id}`

Delete a session.

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - session deleted |
| 404 | Session not found |
| 409 | Session is in progress, cannot delete |

**Example:**

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/{id}/stop`

Stop generation for a session.

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - generation stopped |
| 404 | Session not found |

**Example:**

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/stop \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/{id}/clear`

Clear all messages and usage statistics for a session. The session itself is preserved.

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - session cleared |
| 404 | Session not found |
| 409 | Session is in progress, cannot clear |
| 500 | Failed to clear session |

**Example:**

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/clear \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/{id}/retry`

Retry the last user message. Re-sends the last user message to the AI provider.

> **Note**: Only works if the last message is **not** from the `assistant` role.

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - retry initiated |
| 404 | Session not found |
| 409 | Session is in progress, cannot retry |
| 400 | No message to retry (no messages or last is already assistant) |

**Example:**

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/retry \
  -H "X-API-Key: your-secret-key"
```

---

### DELETE `/session/{id}/messages/{index}`

Delete a specific message from a session by its 1-based index.

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |
| `index` | Message index (1-based) |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - message deleted |
| 400 | Invalid or out-of-range message index |
| 404 | Session not found |
| 409 | Session is in progress, cannot delete message |

**Example:**

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00/messages/3 \
  -H "X-API-Key: your-secret-key"
```

---

### PUT `/session/{id}/provider`

Set the provider for a session.

**Request Body:**

```json
{
  "provider": "anthropic"
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - provider updated |
| 404 | Session not found |
| 400 | Missing or invalid provider value |

**Example:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/provider \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic"}'
```

---

### PUT `/session/{id}/model`

Set the model for a session.

**Request Body:**

```json
{
  "model": "claude-3-5-sonnet-20241022"
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - model updated |
| 404 | Session not found |
| 400 | Missing or invalid model value |

**Example:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/model \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet-20241022"}'
```

---

### PUT `/session/{id}/cwd`

Set the working directory for a session.

**Request Body:**

```json
{
  "cwd": "/path/to/project"
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - working directory updated |
| 404 | Session not found |
| 400 | Missing or invalid cwd value |

**Example:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/cwd \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"cwd": "/home/user/new-project"}'
```

---

### PUT `/session/{id}/pin`

Set the pin status for a session.

**Request Body:**

```json
{
  "pin": true
}
```

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `pin` | boolean | Pin status (`true` = pinned, `false` = unpinned) |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - pin status updated |
| 404 | Session not found |
| 400 | Missing or invalid pin value |

**Examples:**

```bash
# Pin a session
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/pin \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"pin": true}'

# Unpin a session
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/pin \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"pin": false}'
```

---

### PUT `/session/{id}/title`

Set a custom title for a session.

**Request Body:**

```json
{
  "title": "My custom title"
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - title updated |
| 404 | Session not found |
| 400 | Missing or invalid title value |

**Example:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/title \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"title": "Debugging Lua plugin"}'
```

---

### GET `/session/{id}/upload-dir`

Get the upload directory for a session. When set, file uploads via `POST /session/{id}/upload` will be written to this directory instead of the session's `cwd`. Returns `null` if not set (uploads use `cwd`).

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |

**Response (200 OK):**

```json
{
  "upload_dir": "/home/user/uploads"
}
```

When not set:

```json
{
  "upload_dir": null
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success |
| 404 | Session not found |

**Example:**

```bash
curl http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload-dir \
  -H "X-API-Key: your-secret-key"
```

---

### PUT `/session/{id}/upload-dir`

Set the upload directory for a session. Subsequent uploads will write files to this directory. Pass `null` or empty string to reset (uploads will use `cwd`).

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |

**Request Body:**

```json
{
  "upload_dir": "/home/user/uploads"
}
```

To reset to default (use `cwd`):

```json
{
  "upload_dir": null
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - no content |
| 400 | Invalid upload_dir or directory does not exist |
| 404 | Session not found |

**Examples:**

```bash
# Set upload directory
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload-dir \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"upload_dir": "/home/user/uploads"}'

# Reset to use cwd
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload-dir \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"upload_dir": null}'
```

---


### POST `/session/{id}/upload`

Upload a file to the session's upload directory (`cwd`). The raw request body is written directly to the file — **binary-safe**, no base64 encoding required.

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |

**Query Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | Yes* | Relative path within upload directory or `cwd` (e.g., `images/photo.png`) |

*Alternatively, the path can be specified via the `X-Filename` header.

**Request:**

The request body is the raw file content. Set `Content-Type` appropriately (e.g., `image/png`), though it is not validated — the body is written as-is.

**Security:**

- Path must be **relative** (no absolute paths like `/etc/passwd` or `C:\...`)
- Path traversal (`..`) is **rejected**
- The resolved full path must be within the session's upload directory (or `cwd` if not set)
- Parent directories are created automatically

**Response (200 OK):**

```json
{
  "path": "images/photo.png",
  "full_path": "/home/user/project/images/photo.png",
  "size": 102400
}
```

**Response Fields:**

| Field | Type | Description |
|---|---|---|
| `path` | string | Relative path as provided |
| `full_path` | string | Absolute path where the file was written |
| `size` | number | File size in bytes |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success - file uploaded |
| 400 | Missing file path |
| 403 | Path traversal or absolute path rejected |
| 404 | Session not found |
| 500 | Failed to write file |

**Examples:**

```bash
# Upload with ?path= query parameter
curl -X POST "http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload?path=images/photo.png" \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: image/png" \
  --data-binary @photo.png

# Upload with X-Filename header
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload \
  -H "X-API-Key: your-secret-key" \
  -H "X-Filename: assets/logo.svg" \
  -H "Content-Type: image/svg+xml" \
  --data-binary @logo.svg

# Upload to nested directory (auto-created)
curl -X POST "http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload?path=docs/img/diagram.png" \
  -H "X-API-Key: your-secret-key" \
  --data-binary @diagram.png
```

---

### GET `/session/{id}/bridge`

List all integrations bridged to a session.

**Response (200 OK):**

```json
{
  "bridges": ["discord", "lark"]
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success |
| 404 | Session not found |

**Example:**

```bash
curl http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge \
  -H "X-API-Key: your-secret-key"
```

---

### PUT `/session/{id}/bridge/{platform}`

Bridge an integration platform to a session. Once bridged, the integration will receive AI responses for this session.

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |
| `platform` | Integration platform name |

**Available Platforms:** `discord`, `dingtalk`, `lark`, `slack`, `telegram`, `wecom`, `weixin`

**Response (200 OK):**

```json
{
  "session": "2024-01-15-10-30-00",
  "bridge": "discord"
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success - integration bridged |
| 400 | Unknown integration platform (response includes `available` list) |
| 404 | Session not found |

**Example:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge/discord \
  -H "X-API-Key: your-secret-key"
```

---

### DELETE `/session/{id}/bridge/{platform}`

Unbridge a specific integration from a session.

**Path Parameters:**

| Parameter | Description |
|---|---|
| `id` | Session ID |
| `platform` | Integration platform name |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - integration unbridged |
| 400 | Unknown integration platform (response includes `available` list) |
| 404 | Session not found, or integration not bound to this session |
| 404 | Session not found |

**Example:**

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge/discord \
  -H "X-API-Key: your-secret-key"
```

---

### DELETE `/session/{id}/bridge`

Unbridge **all** integrations from a session.

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 204 | Success - all integrations unbridged |
| 404 | Session not found |

**Example:**

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge \
  -H "X-API-Key: your-secret-key"
```

---

### GET `/session`

Get an HTML preview of a session (**no authentication required**, accessible directly from a browser).

**Query Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Session ID |

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success - returns HTML content |
| 400 | Missing `id` parameter |
| 404 | Session not found |

**Examples:**

```bash
# Command line
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"

# Browser
# http://127.0.0.1:7777/session?id=2024-01-15-10-30-00
```

---

### GET `/weixin/login/status`

Poll WeChat login status. The first call auto-starts the login flow (fetches QR code + begins polling). Subsequent calls return the current login state.

If valid credentials already exist (user is logged in), returns `connected` immediately without starting a new login flow.

**Login Flow States:**

```
init → wait → scaned → confirmed (success)
                  ↘ expired (auto-refresh, up to 3 times)

connected (credentials valid, no login flow needed)
```

**Response - Already logged in (connected):**

```json
{
  "status": "connected",
  "message": "✅ 微信已登录",
  "account_id": "bot_id_here",
  "is_running": true
}
```

**Response - Initial call (auto-starts login):**

```json
{
  "status": "init",
  "message": "Login flow started, poll again for QR code"
}
```

**Response - Waiting for scan:**

```json
{
  "status": "wait",
  "qrcode_url": "https://...",
  "session_key": "12345678901234",
  "started_at": 1691500000000,
  "is_fresh": true
}
```

**Response - Scanned, awaiting confirmation:**

```json
{
  "status": "scaned",
  "qrcode_url": "https://...",
  "is_fresh": true
}
```

**Response - Login confirmed (credentials auto-saved):**

```json
{
  "status": "confirmed",
  "qrcode_url": "https://...",
  "is_fresh": true,
  "bot_token": "token_here",
  "account_id": "bot_id_here",
  "base_url": "https://...",
  "user_id": "user_id_here",
  "message": "✅ 微信登录成功！"
}
```

**Response - Expired/timeout:**

```json
{
  "status": "expired",
  "is_fresh": false
}
```

**Response Status Codes:**

| Status Code | Description |
|---|---|
| 200 | Success - returns current login state |
| 500 | Failed to start login flow |

**Client Integration Example:**

```bash
# Poll login status (auto-starts on first call)
while true; do
  resp=$(curl -s http://127.0.0.1:7777/weixin/login/status \
    -H "X-API-Key: your-secret-key")
  status=$(echo "$resp" | jq -r '.status')

  case "$status" in
    init)    echo "Login starting..." ;;
    wait)    echo "Waiting for scan..."; echo "$resp" | jq -r '.qrcode_url' ;;
    scaned)  echo "Scanned, awaiting confirmation..." ;;
    confirmed)
      echo "Login confirmed!"
      echo "$resp" | jq '.bot_token, .account_id'
      break ;;
    connected)
      echo "Already logged in!"
      echo "$resp" | jq '.account_id'
      break ;;
    expired) echo "Login expired, retrying..." ;;
  esac

  sleep 2
done
```

---

### DELETE `/weixin/credentials`

Logout from WeChat. Stops long-polling, clears all stored credentials, state, and login flow data. After logout, the client must re-login via `GET /weixin/login/status` to reconnect.

**What this does:**

1. Stops the polling timer and safety timer
2. Clears the state file (`{storage_dir}/integration/weixin.json`) — removes bot token, sync cursor, context tokens, typing tickets
3. Clears live API credentials from memory
4. Clears any in-progress login flow state (QR code polling)

**Response:**

```json
{
  "status": "logged_out",
  "message": "✅ 微信已退出登录",
  "had_credentials": true
}
```

| Field | Type | Description |
|---|---|---|
| `status` | string | Always `"logged_out"` |
| `message` | string | Human-readable message |
| `had_credentials` | boolean | Whether credentials existed before logout |

**Example:**

```bash
# Logout
curl -X DELETE http://127.0.0.1:7777/weixin/credentials \
  -H "X-API-Key: your-secret-key"
```

---

## Message Queue System

Messages pushed via `POST /` enter an internal queue with intelligent delivery:

```
External App
    │
    ▼
POST / ──► Message Queue
                │
                ├─ Session idle? ──► Deliver immediately (vim.schedule)
                │
                └─ Session busy? ──► Start timer (5s poll)
                                        │
                                        ├─ Session becomes idle ──► Deliver
                                        └─ Still busy ──► Keep polling
```

**How it works:**

1. Messages are immediately queued upon receipt
2. If the session is idle (`in_progress` is false), the message is delivered instantly via `vim.schedule` — no timer delay
3. If the session is busy, a timer starts polling every 5 seconds
4. When the session becomes idle, queued messages are delivered in FIFO order
5. Once all messages are delivered, the timer stops automatically
6. If delivery fails (e.g., session doesn't enter `in_progress`), the message is retried up to 3 times before being dropped

This ensures messages are never lost and are delivered in the order they were sent, with minimal latency for idle sessions.

---

## Common Response Status Codes

These status codes apply across all endpoints:

| Status Code | Description |
|---|---|
| 200 | Success - returns JSON data |
| 204 | Success - no content returned |
| 400 | Bad request (JSON parse error, missing parameters, etc.) |
| 401 | Invalid or missing API key |
| 404 | Resource not found or wrong method/path |

---

## Usage Examples

### curl

```bash
# Send message
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "Hello from curl!"}'

# List sessions
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions

# List providers
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers

# Create new session
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "openai", "model": "gpt-4o"}'

# Set provider
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/provider \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic"}'

# Set model
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/model \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet-20241022"}'

# Set working directory
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/cwd \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"cwd": "/home/user/project"}'

# Pin session
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/pin \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"pin": true}'

# Set title
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/title \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"title": "My custom title"}'

# Delete session
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"

# Stop generation
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/stop \
  -H "X-API-Key: your-secret-key"

# Clear messages
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/clear \
  -H "X-API-Key: your-secret-key"

# Retry last message
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/retry \
  -H "X-API-Key: your-secret-key"

# Delete a specific message (index 3)
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00/messages/3 \
  -H "X-API-Key: your-secret-key"

# Get messages (with pagination)
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00&since=5" \
  -H "X-API-Key: your-secret-key"

# Get raw cache
curl "http://127.0.0.1:7777/sessions/2024-01-15-10-30-00/raw" \
  -H "X-API-Key: your-secret-key"

# Upload a file to session's upload directory (or cwd)
curl -X POST "http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload?path=images/screenshot.png" \
  -H "X-API-Key: your-secret-key" \
  --data-binary @screenshot.png

# Set upload directory
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload-dir \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"upload_dir": "/home/user/uploads"}'

# Get upload directory
curl http://127.0.0.1:7777/session/2024-01-15-10-30-00/upload-dir \
  -H "X-API-Key: your-secret-key"

# Bridge Discord to a session
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge/discord \
  -H "X-API-Key: your-secret-key"

# List bridged integrations
curl http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge \
  -H "X-API-Key: your-secret-key"

# Unbridge a specific integration
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge/discord \
  -H "X-API-Key: your-secret-key"

# Unbridge all integrations
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00/bridge \
  -H "X-API-Key: your-secret-key"

# Logout WeChat
curl -X DELETE http://127.0.0.1:7777/weixin/credentials \
  -H "X-API-Key: your-secret-key"

# Get HTML preview (no API key needed)
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"
```

### Python

```python
import requests

BASE_URL = "http://127.0.0.1:7777"
HEADERS = {"X-API-Key": "your-secret-key"}


# Send a message
def send_message(session_id: str, content: str) -> bool:
    resp = requests.post(
        f"{BASE_URL}/",
        json={"session": session_id, "content": content},
        headers=HEADERS,
    )
    return resp.status_code == 204


# List all sessions
def list_sessions() -> list:
    resp = requests.get(f"{BASE_URL}/sessions", headers=HEADERS)
    return resp.json() if resp.status_code == 200 else []


# List all providers
def list_providers() -> list:
    resp = requests.get(f"{BASE_URL}/providers", headers=HEADERS)
    return resp.json() if resp.status_code == 200 else []


# Create a new session
def create_session(provider: str = None, model: str = None) -> str:
    body = {}
    if provider:
        body["provider"] = provider
    if model:
        body["model"] = model
    resp = requests.post(
        f"{BASE_URL}/session/new",
        json=body if body else None,
        headers=HEADERS,
    )
    return resp.json().get("id") if resp.status_code == 200 else None


# Get messages
def get_messages(session_id: str, since: int = None) -> list:
    params = {"session": session_id}
    if since:
        params["since"] = since
    resp = requests.get(f"{BASE_URL}/messages", params=params, headers=HEADERS)
    return resp.json() if resp.status_code == 200 else []


# Delete a session
def delete_session(session_id: str) -> bool:
    resp = requests.delete(f"{BASE_URL}/session/{session_id}", headers=HEADERS)
    return resp.status_code == 204


# Upload a file to session's working directory
def upload_file(session_id: str, file_path: str, relative_path: str) -> dict:
    with open(file_path, "rb") as f:
        resp = requests.post(
            f"{BASE_URL}/session/{session_id}/upload",
            params={"path": relative_path},
            headers=HEADERS,
            data=f,
        )
    return resp.json() if resp.status_code == 200 else None


# Usage example
if __name__ == "__main__":
    # Create a new session
    session_id = create_session(provider="openai", model="gpt-4o")
    if session_id:
        print(f"Created session: {session_id}")

        # Send a message
        send_message(session_id, "Hello from Python!")

        # List all sessions
        for s in list_sessions():
            print(f"Session: {s['id']}, Provider: {s['provider']}, Messages: {s['message_count']}")
```

### JavaScript / Node.js

```javascript
const BASE_URL = "http://127.0.0.1:7777";
const HEADERS = { "X-API-Key": "your-secret-key" };

// Send a message
async function sendMessage(sessionId, content) {
  const resp = await fetch(`${BASE_URL}/`, {
    method: "POST",
    headers: { ...HEADERS, "Content-Type": "application/json" },
    body: JSON.stringify({ session: sessionId, content }),
  });
  return resp.status === 204;
}

// List sessions
async function listSessions() {
  const resp = await fetch(`${BASE_URL}/sessions`, { headers: HEADERS });
  return resp.ok ? resp.json() : [];
}

// List providers
async function listProviders() {
  const resp = await fetch(`${BASE_URL}/providers`, { headers: HEADERS });
  return resp.ok ? resp.json() : [];
}

// Create a new session
async function createSession(provider, model) {
  const body = {};
  if (provider) body.provider = provider;
  if (model) body.model = model;

  const resp = await fetch(`${BASE_URL}/session/new`, {
    method: "POST",
    headers: { ...HEADERS, "Content-Type": "application/json" },
    body: Object.keys(body).length ? JSON.stringify(body) : undefined,
  });
  return resp.ok ? (await resp.json()).id : null;
}

// Get messages
async function getMessages(sessionId, since) {
  const params = new URLSearchParams({ session: sessionId });
  if (since) params.set("since", since);

  const resp = await fetch(`${BASE_URL}/messages?${params}`, { headers: HEADERS });
  return resp.ok ? resp.json() : [];
}

// Upload a file to session's working directory
async function uploadFile(sessionId, file, relativePath) {
  const params = new URLSearchParams({ path: relativePath });
  const resp = await fetch(`${BASE_URL}/session/${sessionId}/upload?${params}`, {
    method: "POST",
    headers: HEADERS,
    body: file,
  });
  return resp.ok ? resp.json() : null;
}

// Usage example
(async () => {
  const sessionId = await createSession("openai", "gpt-4o");
  if (sessionId) {
    console.log(`Created session: ${sessionId}`);

    await sendMessage(sessionId, "Hello from Node.js!");

    const sessions = await listSessions();
    sessions.forEach((s) =>
      console.log(`Session: ${s.id}, Provider: ${s.provider}, Messages: ${s.message_count}`)
    );
  }
})();
```

---

## Security Considerations

> ⚠️ **Important Security Notes**

1. **API Key Protection**: Use a strong key (generate with `openssl rand -hex 32`). Never commit it to version control
2. **Network Isolation**: The server binds to `127.0.0.1` by default (local only). If exposing externally, use an HTTPS reverse proxy
3. **Input Validation**: All request bodies are validated for proper JSON format and field types
4. **Rate Limiting**: Implement external rate limiting if needed for your use case

---

## Integration Ideas

### CI/CD Pipelines

```bash
# Send build notifications to a chat session
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d "{\"session\": \"$SESSION_ID\", \"content\": \"Build #$BUILD_NUMBER completed: $STATUS\"}"
```

### Monitoring Dashboard

```javascript
// Display providers and models in a web dashboard
async function updateDashboard() {
  const resp = await fetch("http://127.0.0.1:7777/providers", {
    headers: { "X-API-Key": "your-secret-key" },
  });
  const providers = await resp.json();

  document.getElementById("provider-list").innerHTML = providers
    .map((p) => `<li>${p.name} - ${p.models.length} models</li>`)
    .join("");
}
```

---

## Next Steps

- [Providers](../providers/) - AI provider configuration
- [Tools](../tools/) - Tool system
- [Memory System](../memory/) - Memory system configuration
- [IM Integration](../integrations/) - Instant messaging integrations


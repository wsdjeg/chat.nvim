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

chat.nvim includes a built-in HTTP server that allows external applications to send messages to your chat sessions. This enables integration with other tools, scripts, and automation workflows.

## Enabling the HTTP Server

The HTTP server is automatically started when the `http.api_key` configuration is set to a non-empty value:

```lua
require('chat').setup({
  -- ... other configuration
  http = {
    host = '127.0.0.1',    -- Default: '127.0.0.1'
    port = 7777,           -- Default: 7777
    api_key = 'your-secret-key', -- Required to enable server
  },
})
```

| Endpoint                | Method | Description                                               |
| ----------------------- | ------ | --------------------------------------------------------- |
| `/`                     | POST   | Send messages to a specified chat session                 |
| `/sessions`             | GET    | Get a list of all sessions with details                   |
| `/providers`            | GET    | Get a list of all supported AI providers                  |
| `/session/new`          | POST   | Create a new session                                      |
| `/session/:id`          | DELETE | Delete a session                                          |
| `/session/:id/stop`     | POST   | Stop generation for a session                             |
| `/session/:id/retry`    | POST   | Retry last message for a session                          |
| `/session/:id/provider` | PUT    | Set provider for a session                                |
| `/session/:id/model`    | PUT    | Set model for a session                                   |
| `/session`              | GET    | Get HTML preview of a session (requires `id` parameter)   |
| `/messages`             | GET    | Get message list for a session (requires `session` param) |

**Base URL**: `http://{host}:{port}/` where `{host}` and `{port}` are configured in your chat.nvim settings (default: `127.0.0.1:7777`)

**Authentication**: All requests (except GET /session for HTML preview) require the `X-API-Key` header containing your configured API key.

**Example Usage**:

```bash
# Send message to session
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "my-session", "content": "Hello from curl!"}'

# Get session list
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions

# Get providers list
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers

# Create new session
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "openai", "model": "gpt-4o"}'
```

---

## Request Format

### POST `/`

Send a message to a specific chat session.

**Request Body**:

```json
{
  "session": "session-id",
  "content": "Message content from external application"
}
```

**Parameters**:

| Parameter | Type   | Description                                 |
| --------- | ------ | ------------------------------------------- |
| `session` | string | Chat session ID.                            |
| `content` | string | Message content to send to the chat session |

**Example**:

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "What is the weather today?"}'
```

### POST `/session/new`

Create a new chat session.

**Response** (200 OK):

```json
{
  "session_id": "2024-01-15-10-30-00"
}
```

**Example**:

### PUT `/session/:id/provider`

Set the provider for a specific session.

**Path Parameters**:

| Parameter | Type   | Description |
| --------- | ------ | ----------- |
| `id`      | string | Session ID  |

**Request Body**:

```json
{
  "provider": "openai"
}
```

**Response**:

| Status Code | Description                               |
| ----------- | ----------------------------------------- |
| 204         | Success - Provider updated                |
| 404         | Not Found - Session does not exist        |
| 400         | Bad Request - Missing or invalid provider |
| 401         | Unauthorized - Invalid or missing API key |

**Example**:

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/provider \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic"}'
```

### PUT `/session/:id/model`

Set the model for a specific session.

**Path Parameters**:

| Parameter | Type   | Description |
| --------- | ------ | ----------- |
| `id`      | string | Session ID  |

**Request Body**:

```json
{
  "model": "gpt-4o"
}
```

**Response**:

| Status Code | Description                               |
| ----------- | ----------------------------------------- |
| 204         | Success - Model updated                   |
| 404         | Not Found - Session does not exist        |
| 400         | Bad Request - Missing or invalid model    |
| 401         | Unauthorized - Invalid or missing API key |

**Example**:

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/model \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet-20241022"}'
```

```bash
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key"
```

### DELETE `/session/:id`

Delete a specific session.

**Path Parameters**:

| Parameter | Type   | Description          |
| --------- | ------ | -------------------- |
| `id`      | string | Session ID to delete |

**Response**:

| Status Code | Description                               |
| ----------- | ----------------------------------------- |
| 204         | Success - Session deleted successfully    |
| 404         | Not Found - Session does not exist        |
| 409         | Conflict - Session is in progress         |
| 401         | Unauthorized - Invalid or missing API key |

**Example**:

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"
```

### POST `/session/:id/stop`

Stop an ongoing generation for a specific session.

**Path Parameters**:

| Parameter | Type   | Description                   |
| --------- | ------ | ----------------------------- |
| `id`      | string | Session ID to stop generation |

**Response**:

| Status Code | Description                               |
| ----------- | ----------------------------------------- |
| 204         | Success - Generation stopped              |
| 404         | Not Found - Session does not exist        |
| 401         | Unauthorized - Invalid or missing API key |

**Example**:

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/stop \
  -H "X-API-Key: your-secret-key"
```

### POST `/session/:id/retry`

Retry the last message for a specific session. This will resend the last user message to the AI.

**Path Parameters**:

| Parameter | Type   | Description         |
| --------- | ------ | ------------------- |
| `id`      | string | Session ID to retry |

**Response**:

| Status Code | Description                               |
| ----------- | ----------------------------------------- |
| 204         | Success - Retry initiated                 |
| 404         | Not Found - Session does not exist        |
| 409         | Conflict - Session is in progress         |
| 400         | Bad Request - No message to retry         |
| 401         | Unauthorized - Invalid or missing API key |

**Example**:

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/retry \
  -H "X-API-Key: your-secret-key"
```

---

## Response Format

### POST `/`

| Status Code | Description                                           |
| ----------- | ----------------------------------------------------- |
| 204         | Success - Message queued successfully                 |
| 401         | Unauthorized - Invalid or missing API key             |
| 400         | Bad Request - Invalid JSON or missing required fields |
| 404         | Not Found - Wrong method or path                      |

### GET `/sessions`

Returns a JSON array of session objects with details.

**Success Response** (200 OK):

```json
[
  {
    "id": "2024-01-15-10-30-00",
    "title": "Help me write a Lua plugin...",
    "cwd": "/home/user/project",
    "provider": "openai",
    "model": "gpt-4o",
    "in_progress": false,
    "message_count": 5,
    "last_message": {
      "role": "assistant",
      "content": "I'd be happy to help you write a Lua plugin for Neovim. Let's start by...",
      "created": 1705315800
    }
  },
  {
    "id": "2024-01-15-11-45-00",
    "title": "Explain this error message...",
    "cwd": "/home/user/another-project",
    "provider": "anthropic",
    "model": "claude-3-5-sonnet-20241022",
    "in_progress": true,
    "message_count": 3,
    "last_message": {
      "role": "user",
      "content": "Can you also check the log file for more details?",
      "created": 1705316700
    }
  }
]
```

**Fields**:

| Field           | Type    | Description                                                     |
| --------------- | ------- | --------------------------------------------------------------- |
| `id`            | string  | Session ID (format: `YYYY-MM-DD-HH-MM-SS`)                      |
| `title`         | string  | Session title (extracted from first user message, max 50 chars) |
| `cwd`           | string  | Working directory for the session                               |
| `provider`      | string  | AI provider name                                                |
| `model`         | string  | Model name                                                      |
| `in_progress`   | boolean | Whether the session has an active request                       |
| `message_count` | number  | Total number of messages in the session                         |
| `last_message`  | object  | Last message object (null if no messages)                       |

**Last Message Object**:

| Field     | Type   | Description                                   |
| --------- | ------ | --------------------------------------------- |
| `role`    | string | Message role (`user` or `assistant`)          |
| `content` | string | Message content (truncated to 100 characters) |
| `created` | number | Unix timestamp of message creation            |

### GET `/providers`

Returns a JSON array of supported AI providers with their available models.

**Success Response** (200 OK):

```json
[
  {
    "name": "anthropic",
    "models": ["claude-3-5-sonnet-20241022", "claude-3-opus-20240229"]
  },
  {
    "name": "deepseek",
    "models": ["deepseek-chat", "deepseek-coder"]
  },
  {
    "name": "openai",
    "models": ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
  }
]
```

**Fields**:

| Field    | Type         | Description                                 |
| -------- | ------------ | ------------------------------------------- |
| `name`   | string       | Provider name (e.g., "openai", "anthropic") |
| `models` | string array | List of available models for this provider  |

**Example**:

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers
```

### GET `/messages`

Returns the message list for a specific session.

**Query Parameters**:

| Parameter | Type   | Description                                                                 |
| --------- | ------ | --------------------------------------------------------------------------- |
| `session` | string | **Required**. Session ID                                                   |
| `since`   | number | **Optional**. Return messages starting from this index (1-indexed)        |

**Example**:

```bash
# Get all messages
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"

# Get messages starting from index 5
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00&since=5" \
  -H "X-API-Key: your-secret-key"
```

**Success Response** (200 OK):

Returns an array of messages in chronological order (oldest first).

```json
[
  {
    "role": "user",
    "content": "Hello!"
  },
  {
    "role": "assistant",
    "content": "Hi there! How can I help you?"
  }
]
```

**Message Fields**:

| Field                | Type   | Description                                      |
| -------------------- | ------ | ------------------------------------------------ |
| `role`               | string | Message role: `user`, `assistant`, or `tool`    |
| `content`            | string | Message content (may be null for tool calls)     |
| `reasoning_content`  | string | Optional. Reasoning content (for thinking models)|
| `tool_calls`         | array  | Optional. Tool calls made by assistant           |
| `tool_call_id`       | string | Optional. Tool call ID (for tool role messages)  |
| `created`            | number | Optional. Timestamp when message was created     |
| `usage`              | object | Optional. Token usage statistics                 |
| `error`              | string | Optional. Error message if request failed         |
| `tool_call_state`    | string | Optional. Tool call execution state              |

**Message Order**:

- Messages are returned in chronological order (oldest to newest)
- Index is 1-based (first message is at index 1)
- `since` parameter uses this 1-based index

**Error Responses**:

| Status Code | Description                          |
| ----------- | ------------------------------------ |
| 400         | Bad Request - Missing session param  |
| 404         | Not Found - Session does not exist   |

### GET `/session`

Returns an HTML preview of the specified chat session (no authentication required).

**Query Parameters**:

| Parameter | Type   | Description                         |
| --------- | ------ | ----------------------------------- |
| `id`      | string | **Required**. Session ID to preview |

**Example Request**:

```bash
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"
```

**Response**:

| Status Code | Description                      |
| ----------- | -------------------------------- |
| 200         | Success - Returns HTML content   |
| 400         | Bad Request - Missing session ID |
| 404         | Not Found - Session not found    |

> Note: The GET /session endpoint does not require authentication (no API key needed) to allow easy HTML preview in browsers.

---

## Message Queue System

Incoming messages are processed through a queue system to ensure reliability:

{: .highlight }

1. Messages are immediately queued upon receipt
2. The queue is checked every 5 seconds
3. Messages are delivered to the chat session when it's not in progress
4. If a session is busy (processing another request), messages remain in the queue until the session becomes available

This ensures that messages are never lost and are delivered in the order they were received.

## Usage Examples

### Using curl

**Send a message**:

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "Hello from curl!"}'
```

**Get session list**:

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

**Get providers list**:

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers
```

**Create new session**:

```bash
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "openai", "model": "gpt-4o"}'
```

**Set provider**:

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/provider \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic"}'
```

**Set model**:

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/model \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet-20241022"}'
```

**Delete session**:

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"
```

**Stop generation**:

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/stop \
  -H "X-API-Key: your-secret-key"
```

**Retry last message**:

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/retry \
  -H "X-API-Key: your-secret-key"
```

**Get session preview**:

```bash
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"
```

### Using Python

**Send a message**:

```python
import requests

url = "http://127.0.0.1:7777/"
headers = {
    "X-API-Key": "your-secret-key",
    "Content-Type": "application/json"
}
data = {
    "session": "2024-01-15-10-30-00",
    "content": "Message from Python script"
}
response = requests.post(url, json=data, headers=headers)
print(f"Status: {response.status_code}")
```

**Get session list**:

```python
import requests

headers = {"X-API-Key": "your-secret-key"}
sessions_response = requests.get("http://127.0.0.1:7777/sessions", headers=headers)
if sessions_response.status_code == 200:
    sessions = sessions_response.json()
    for session in sessions:
        print(f"Session: {session['id']}, Provider: {session['provider']}, Model: {session['model']}")
```

**Get providers list**:

```python
import requests

headers = {"X-API-Key": "your-secret-key"}
providers_response = requests.get("http://127.0.0.1:7777/providers", headers=headers)
if providers_response.status_code == 200:
    providers = providers_response.json()
    for provider in providers:
        print(f"Provider: {provider['name']}, Models: {provider['models']}")
```

**Create new session**:

```python
import requests

headers = {"X-API-Key": "your-secret-key"}
response = requests.post("http://127.0.0.1:7777/session/new", headers=headers)
if response.status_code == 200:
    session_id = response.json()["session_id"]
    print(f"Created session: {session_id}")
```

**Delete session**:

```python
import requests

session_id = "2024-01-15-10-30-00"
headers = {"X-API-Key": "your-secret-key"}
response = requests.delete(f"http://127.0.0.1:7777/session/{session_id}", headers=headers)
if response.status_code == 204:
    print("Session deleted successfully")
elif response.status_code == 409:
    print("Cannot delete: session is in progress")
```

### Using JavaScript/Node.js

**Send a message**:

```javascript
const axios = require("axios");

async function sendMessage(sessionId, content) {
  try {
    const response = await axios.post(
      "http://127.0.0.1:7777/",
      { session: sessionId, content: content },
      {
        headers: {
          "X-API-Key": "your-secret-key",
          "Content-Type": "application/json",
        },
      },
    );
    console.log("Message sent successfully");
  } catch (error) {
    console.error("Error:", error.response?.status);
  }
}

sendMessage("2024-01-15-10-30-00", "Hello from Node.js!");
```

**Get providers list**:

```javascript
const axios = require("axios");

async function getProviders() {
  try {
    const response = await axios.get("http://127.0.0.1:7777/providers", {
      headers: { "X-API-Key": "your-secret-key" },
    });
    console.log("Providers:", response.data);
    return response.data;
  } catch (error) {
    console.error("Error:", error.response?.status);
  }
}

getProviders();
```

---

## Security Considerations

{: .warning }
**Important Security Notes**:

1. **API Key Protection**: Keep your API key secure and never commit it to version control
2. **Network Security**: By default, the server binds to localhost (127.0.0.1). Only allow external access if you have proper network security measures
3. **Input Validation**: All incoming messages are validated for proper JSON format and required fields
4. **Rate Limiting**: Consider implementing external rate limiting if needed for your use case

**Best Practices**:

- Use strong, unique API keys (generate with: `openssl rand -hex 32`)
- If exposing the server externally, use HTTPS with a reverse proxy
- Monitor the server logs for suspicious activity
- Restrict access to trusted IP addresses if possible

---

## Integration Ideas

The HTTP API opens up many possibilities for integration:

### CI/CD Pipelines

Send build notifications or deployment status to chat sessions:

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d "{\"session\": \"$SESSION_ID\", \"content\": \"Build completed successfully!\"}"
```

### Monitoring Dashboard

Display providers and models in a web dashboard:

```javascript
async function updateDashboard() {
  const response = await fetch("http://127.0.0.1:7777/providers", {
    headers: { "X-API-Key": "your-secret-key" },
  });
  const providers = await response.json();

  document.getElementById("provider-list").innerHTML = providers
    .map((p) => `<li>${p.name} - ${p.models.length} models</li>`)
    .join("");
}
```

---

## Next Steps

- [Providers](../providers/) - Learn about AI providers
- [Tools](../tools/) - Explore available tools
- [Memory System](../memory/) - Memory system configuration
- [IM Integration](../integrations/im/) - Instant messaging integrations

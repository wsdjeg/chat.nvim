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

{: .warning }

> The HTTP server will not start if `http.api_key` is empty or not set.

---

## API Endpoints

chat.nvim provides the following HTTP API endpoints for external integration:

| Endpoint        | Method | Description                                              |
| --------------- | ------ | -------------------------------------------------------- |
| `/`             | POST   | Send messages to a specified chat session                |
| `/sessions`     | GET    | Get a list of all sessions with details                  |
| `/session/new`  | POST   | Create a new session                                     |
| `/session/:id`  | DELETE | Delete a session                                         |
| `/session`      | GET    | Get HTML preview of a session (requires `id` parameter)  |
| `/messages`     | GET    | Get message list for a session (requires `session` param) |

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

Create a new chat session with optional configuration.

**Request Body** (all fields optional):

```json
{
  "cwd": "/path/to/project",
  "provider": "openai",
  "model": "gpt-4o"
}
```

**Parameters**:

| Parameter  | Type   | Description                                      |
| ---------- | ------ | ------------------------------------------------ |
| `cwd`      | string | Working directory for the session (optional)    |
| `provider` | string | AI provider name (optional)                     |
| `model`    | string | Model name (optional)                           |

**Response** (201 Created):

```json
{
  "id": "2024-01-15-10-30-00"
}
```

**Example**:

```bash
# Create session with default settings
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key"

# Create session with custom settings
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic", "model": "claude-3-5-sonnet-20241022"}'
```

### DELETE `/session/:id`

Delete a specific session.

**Path Parameters**:

| Parameter | Type   | Description          |
| --------- | ------ | -------------------- |
| `id`      | string | Session ID to delete |

**Response**:

| Status Code | Description                                    |
| ----------- | ---------------------------------------------- |
| 204         | Success - Session deleted successfully         |
| 404         | Not Found - Session does not exist             |
| 409         | Conflict - Session is in progress              |
| 401         | Unauthorized - Invalid or missing API key      |

**Example**:

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
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
    "cwd": "/home/user/project",
    "provider": "openai",
    "model": "gpt-4o"
  },
  {
    "id": "2024-01-15-11-45-00",
    "cwd": "/home/user/another-project",
    "provider": "anthropic",
    "model": "claude-3-5-sonnet-20241022"
  }
]
```

**Fields**:

| Field     | Type   | Description                             |
| --------- | ------ | --------------------------------------- |
| `id`      | string | Session ID (format: `YYYY-MM-DD-HH-MM-SS`) |
| `cwd`     | string | Working directory for the session       |
| `provider`| string | AI provider name                        |
| `model`   | string | Model name                              |

{: .info }

> Session IDs follow the format `YYYY-MM-DD-HH-MM-SS` (e.g., `2024-01-15-10-30-00`) and are automatically generated when new sessions are created.

### GET `/messages`

Returns the message list for a specific session.

**Query Parameters**:

| Parameter | Type   | Description                    |
| --------- | ------ | ------------------------------ |
| `session` | string | **Required**. Session ID      |

**Example**:

```bash
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"
```

**Success Response** (200 OK):

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

### GET `/session`

Returns an HTML preview of the specified chat session.

**Request Parameters**:

| Parameter | Type   | Description                         |
| --------- | ------ | ----------------------------------- |
| `id`      | string | **Required**. Session ID to preview |

**Example Request**:

```bash
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"
```

**Response**:

| Status Code | Description                               |
| ----------- | ----------------------------------------- |
| 200         | Success - Returns HTML content            |
| 400         | Bad Request - Missing session ID          |
| 404         | Not Found - Session not found             |

{: .info }

> Note: The GET /session endpoint does not require authentication (no API key needed) to allow easy HTML preview in browsers.

**HTML Preview Features**:

- Clean, modern dark theme design
- Session metadata display (ID, provider, model, working directory, system prompt)
- Message formatting with role badges and timestamps
- Support for tool calls and results visualization
- Reasoning content (thinking) display
- Error messages highlighting
- Token usage statistics
- Responsive layout with scrollable sections

---

## Message Queue System

Incoming messages are processed through a queue system to ensure reliability:

{: .highlight }

1. Messages are immediately queued upon receipt
2. The queue is checked every 5 seconds
3. Messages are delivered to the chat session when it's not in progress
4. If a session is busy (processing another request), messages remain in the queue until the session becomes available

This ensures that messages are never lost and are delivered in the order they were received.

---

## Usage Examples

### Using curl

**Send a message**:

```bash
# Send a message to a specific session
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "Hello from curl!"}'
```

**Get session list**:

```bash
# Get all sessions with details
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

**Create new session**:

```bash
# Create session with default settings
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key"

# Create session with custom settings
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"cwd": "/home/user/my-project", "provider": "anthropic"}'
```

**Delete session**:

```bash
# Delete a session
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"
```

**Get session preview**:

```bash
# Get HTML preview of a session
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"
```

### Using Python

**Send a message**:

```python
import requests

# Send a message to a session
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

# Get session list with details
headers = {"X-API-Key": "your-secret-key"}
sessions_response = requests.get("http://127.0.0.1:7777/sessions", headers=headers)
if sessions_response.status_code == 200:
    sessions = sessions_response.json()
    for session in sessions:
        print(f"Session: {session['id']}, Provider: {session['provider']}, Model: {session['model']}")
```

**Create new session**:

```python
import requests

# Create a new session
headers = {"X-API-Key": "your-secret-key"}
data = {
    "cwd": "/home/user/my-project",
    "provider": "openai",
    "model": "gpt-4o"
}
response = requests.post("http://127.0.0.1:7777/session/new", json=data, headers=headers)
if response.status_code == 201:
    session_id = response.json()["id"]
    print(f"Created session: {session_id}")
```

**Delete session**:

```python
import requests

# Delete a session
session_id = "2024-01-15-10-30-00"
headers = {"X-API-Key": "your-secret-key"}
response = requests.delete(f"http://127.0.0.1:7777/session/{session_id}", headers=headers)
if response.status_code == 204:
    print("Session deleted successfully")
elif response.status_code == 409:
    print("Cannot delete: session is in progress")
```

**Get session preview**:

```python
import requests

# Get HTML preview
params = {"id": "2024-01-15-10-30-00"}
response = requests.get("http://127.0.0.1:7777/session", params=params)
if response.status_code == 200:
    html_content = response.text
    print("Preview generated successfully")
```

### Using JavaScript/Node.js

**Send a message**:

```javascript
const axios = require("axios");

// Send a message to a session
async function sendMessage(sessionId, content) {
  try {
    const response = await axios.post(
      "http://127.0.0.1:7777/",
      {
        session: sessionId,
        content: content,
      },
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

**Get session list**:

```javascript
const axios = require("axios");

// Get all sessions with details
async function getSessions() {
  try {
    const response = await axios.get("http://127.0.0.1:7777/sessions", {
      headers: { "X-API-Key": "your-secret-key" },
    });
    console.log("Sessions:", response.data);
    return response.data;
  } catch (error) {
    console.error("Error:", error.response?.status);
  }
}

getSessions();
```

**Create new session**:

```javascript
const axios = require("axios");

// Create a new session
async function createSession(cwd, provider, model) {
  try {
    const response = await axios.post(
      "http://127.0.0.1:7777/session/new",
      { cwd, provider, model },
      {
        headers: {
          "X-API-Key": "your-secret-key",
          "Content-Type": "application/json",
        },
      },
    );
    console.log("Created session:", response.data.id);
    return response.data.id;
  } catch (error) {
    console.error("Error:", error.response?.status);
  }
}

createSession("/home/user/project", "openai", "gpt-4o");
```

**Delete session**:

```javascript
const axios = require("axios");

// Delete a session
async function deleteSession(sessionId) {
  try {
    const response = await axios.delete(
      `http://127.0.0.1:7777/session/${sessionId}`,
      {
        headers: { "X-API-Key": "your-secret-key" },
      },
    );
    console.log("Session deleted successfully");
  } catch (error) {
    if (error.response?.status === 409) {
      console.error("Cannot delete: session is in progress");
    } else {
      console.error("Error:", error.response?.status);
    }
  }
}

deleteSession("2024-01-15-10-30-00");
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
# In your CI/CD script
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d "{\"session\": \"$SESSION_ID\", \"content\": \"Build completed successfully!\"}"
```

### Monitoring Systems

Forward alerts from monitoring tools:

```python
import requests

def send_alert(session_id, alert_message):
    requests.post('http://127.0.0.1:7777/',
        json={'session': session_id, 'content': alert_message},
        headers={'X-API-Key': 'your-secret-key'})
```

### Script Automation

Trigger chat interactions from shell scripts:

```bash
#!/bin/bash
# Daily report script
REPORT=$(generate_daily_report)
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d "{\"session\": \"$SESSION_ID\", \"content\": \"Daily Report:\n$REPORT\"}"
```

### External Applications

Integrate with other desktop or web applications:

```javascript
// Electron app integration
const { ipcMain } = require("electron");
const axios = require("axios");

ipcMain.handle("send-to-chat", async (event, message) => {
  const response = await axios.post(
    "http://127.0.0.1:7777/",
    {
      session: "electron-app",
      content: message,
    },
    {
      headers: { "X-API-Key": "your-secret-key" },
    },
  );
  return response.status === 204;
});
```

### Session Management Tools

External scripts can manage sessions programmatically:

```python
import requests

def backup_sessions():
    headers = {'X-API-Key': 'your-secret-key'}
    
    # Get all sessions
    response = requests.get('http://127.0.0.1:7777/sessions', headers=headers)
    sessions = response.json()
    
    for session in sessions:
        session_id = session['id']
        
        # Get messages for backup
        msgs = requests.get(
            f'http://127.0.0.1:7777/messages?session={session_id}',
            headers=headers
        )
        
        with open(f'backup_{session_id}.json', 'w') as f:
            json.dump(msgs.json(), f)

def cleanup_old_sessions(days_old=30):
    """Delete sessions older than specified days"""
    headers = {'X-API-Key': 'your-secret-key'}
    
    response = requests.get('http://127.0.0.1:7777/sessions', headers=headers)
    sessions = response.json()
    
    cutoff = datetime.now() - timedelta(days=days_old)
    
    for session in sessions:
        session_date = datetime.strptime(session['id'], '%Y-%m-%d-%H-%M-%S')
        if session_date < cutoff:
            # Delete old session
            requests.delete(
                f'http://127.0.0.1:7777/session/{session["id"]}',
                headers=headers
            )
```

### Monitoring Dashboard

Display status and statistics of all active sessions:

```javascript
// Web dashboard
async function updateDashboard() {
  const response = await fetch("http://127.0.0.1:7777/sessions", {
    headers: { "X-API-Key": "your-secret-key" },
  });
  const sessions = await response.json();

  // Update dashboard UI
  document.getElementById("session-count").textContent = sessions.length;
  document.getElementById("session-list").innerHTML = sessions
    .map((s) => `<li>${s.id} - ${s.provider}/${s.model}</li>`)
    .join("");
}

// Update every 5 seconds
setInterval(updateDashboard, 5000);
```

---

## Next Steps

- [Providers](../providers/) - Learn about AI providers
- [Tools](../tools/) - Explore available tools
- [Memory System](../memory/) - Memory system configuration
- [IM Integration](../integrations/im/) - Instant messaging integrations

---
layout: default
title: HTTP API
parent: API
nav_order: 1
---

# HTTP API

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
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

| Endpoint    | Method | Description                                             |
| ----------- | ------ | ------------------------------------------------------- |
| `/`         | POST   | Send messages to a specified chat session               |
| `/sessions` | GET    | Get a list of all active session IDs                    |
| `/session`  | GET    | Get HTML preview of a session (requires `id` parameter) |

**Base URL**: `http://{host}:{port}/` where `{host}` and `{port}` are configured in your chat.nvim settings (default: `127.0.0.1:7777`)

**Authentication**: All requests require the `X-API-Key` header containing your configured API key.

**Example Usage**:

```bash
# Send message to session
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "my-session", "content": "Hello from curl!"}'

# Get session list
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
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

---

## Response Format

### POST `/`

| Status Code | Description                                                      |
| ----------- | ---------------------------------------------------------------- |
| 204         | Success - Message queued successfully                            |
| 401         | Unauthorized - Invalid or missing API key                        |
| 400         | Bad Request - Invalid JSON or missing required fields            |
| 404         | Not Found - Wrong method or path                                 |

### GET `/sessions`

Returns a JSON array of active session IDs.

**Success Response** (200 OK):

```json
[
  "2024-01-15-10-30-00",
  "2024-01-15-11-45-00",
  "2024-01-16-09-20-00"
]
```

{: .info }
> Session IDs follow the format `YYYY-MM-DD-HH-MM-SS` (e.g., `2024-01-15-10-30-00`) and are automatically generated when new sessions are created.

### GET `/session`

Returns an HTML preview of the specified chat session.

**Request Parameters**:

| Parameter | Type   | Description                         |
| --------- | ------ | ----------------------------------- |
| `id`      | string | **Required**. Session ID to preview |

**Example Request**:

```bash
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"
```

**Response**:

| Status Code | Description                                    |
| ----------- | ---------------------------------------------- |
| 200         | Success - Returns HTML content                 |
| 400         | Bad Request - Missing session ID               |
| 404         | Not Found - Session not found                  |
| 401         | Unauthorized - Invalid or missing API key      |

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
# Get all active session IDs
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

**Get session preview**:

```bash
# Get HTML preview of a session
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"
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
    "session": "python-script",
    "content": "Message from Python script"
}
response = requests.post(url, json=data, headers=headers)
print(f"Status: {response.status_code}")
```

**Get session list**:

```python
import requests

# Get session list
headers = {"X-API-Key": "your-secret-key"}
sessions_response = requests.get("http://127.0.0.1:7777/sessions", headers=headers)
if sessions_response.status_code == 200:
    sessions = sessions_response.json()
    print(f"Active sessions: {sessions}")
```

**Get session preview**:

```python
import requests

# Get HTML preview
headers = {"X-API-Key": "your-secret-key"}
params = {"id": "2024-01-15-10-30-00"}
response = requests.get("http://127.0.0.1:7777/session", headers=headers, params=params)
if response.status_code == 200:
    html_content = response.text
    print("Preview generated successfully")
```

### Using JavaScript/Node.js

**Send a message**:

```javascript
const axios = require('axios');

// Send a message to a session
async function sendMessage(sessionId, content) {
  try {
    const response = await axios.post('http://127.0.0.1:7777/', {
      session: sessionId,
      content: content
    }, {
      headers: {
        'X-API-Key': 'your-secret-key',
        'Content-Type': 'application/json'
      }
    });
    console.log('Message sent successfully');
  } catch (error) {
    console.error('Error:', error.response?.status);
  }
}

sendMessage('2024-01-15-10-30-00', 'Hello from Node.js!');
```

**Get session list**:

```javascript
const axios = require('axios');

// Get all active sessions
async function getSessions() {
  try {
    const response = await axios.get('http://127.0.0.1:7777/sessions', {
      headers: { 'X-API-Key': 'your-secret-key' }
    });
    console.log('Active sessions:', response.data);
    return response.data;
  } catch (error) {
    console.error('Error:', error.response?.status);
  }
}

getSessions();
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
const { ipcMain } = require('electron');
const axios = require('axios');

ipcMain.handle('send-to-chat', async (event, message) => {
  const response = await axios.post('http://127.0.0.1:7777/', {
    session: 'electron-app',
    content: message
  }, {
    headers: { 'X-API-Key': 'your-secret-key' }
  });
  return response.status === 204;
});
```

### Session Management Tools

External scripts can periodically fetch active session lists for cleanup or backup:

```python
import requests
import json

def backup_sessions():
    headers = {'X-API-Key': 'your-secret-key'}
    response = requests.get('http://127.0.0.1:7777/sessions', headers=headers)
    sessions = response.json()
    
    for session_id in sessions:
        # Backup each session
        preview = requests.get(
            'http://127.0.0.1:7777/session',
            params={'id': session_id},
            headers=headers
        )
        with open(f'backup_{session_id}.html', 'w') as f:
            f.write(preview.text)
```

### Monitoring Dashboard

Display status and statistics of all active sessions:

```javascript
// Web dashboard
async function updateDashboard() {
  const response = await fetch('http://127.0.0.1:7777/sessions', {
    headers: { 'X-API-Key': 'your-secret-key' }
  });
  const sessions = await response.json();
  
  // Update dashboard UI
  document.getElementById('session-count').textContent = sessions.length;
  document.getElementById('session-list').innerHTML = 
    sessions.map(id => `<li>${id}</li>`).join('');
}

// Update every 5 seconds
setInterval(updateDashboard, 5000);
```

---

## Next Steps

- [Providers](/docs/providers/) - Learn about AI providers
- [Tools](/docs/tools/) - Explore available tools
- [Memory System](/docs/memory/) - Memory system configuration
- [IM Integration](/docs/integrations/im/) - Instant messaging integrations


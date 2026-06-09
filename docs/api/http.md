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

chat.nvim 内置了一个基于 libuv TCP 的 HTTP 服务器，允许外部应用与聊天会话交互。
这使得 CLI 工具、CI/CD 流水线、Web 应用等都能通过 HTTP API 发送消息到 Neovim 会话。

---

## 启用 HTTP 服务器

设置 `http.api_key` 为非空值即可自动启用：

```lua
require('chat').setup({
  -- ... other configuration
  http = {
    host = '127.0.0.1',  -- 默认: '127.0.0.1'
    port = 7777,          -- 默认: 7777
    api_key = 'your-secret-key',  -- 必填，用于启用服务器
  },
})
```

**Base URL**: `http://{host}:{port}`

**认证方式**: 除 `GET /session`（HTML 预览）外，所有请求都需要在 HTTP 头中携带 `X-API-Key`。

---

## 端点一览

| 端点 | 方法 | 说明 |
|---|---|---|
| `/` | POST | 推送消息到会话队列 |
| `/sessions` | GET | 获取所有会话列表 |
| `/sessions/{id}` | GET | 获取单个会话详情 |
| `/sessions/{id}/raw` | GET | 获取会话原始缓存 JSON |
| `/providers` | GET | 获取所有可用 Provider 及其模型 |
| `/messages` | GET | 获取会话消息列表 |
| `/session/new` | POST | 创建新会话 |
| `/session/{id}` | DELETE | 删除会话 |
| `/session/{id}/stop` | POST | 停止生成 |
| `/session/{id}/clear` | POST | 清空会话消息 |
| `/session/{id}/retry` | POST | 重试最后一条消息 |
| `/session/{id}/provider` | PUT | 设置会话 Provider |
| `/session/{id}/model` | PUT | 设置会话模型 |
| `/session/{id}/cwd` | PUT | 设置会话工作目录 |
| `/session/{id}/pin` | PUT | 设置会话置顶状态 |
| `/session/{id}/title` | PUT | 设置会话标题 |
| `/session` | GET | 获取会话 HTML 预览（无需认证） |

---

## 端点详情

### POST `/`

推送消息到指定会话的消息队列。

**Request Body:**

```json
{
  "session": "2024-01-15-10-30-00",
  "content": "Hello from external app!"
}
```

**参数:**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `session` | string | 是 | 目标会话 ID |
| `content` | string | 是 | 消息内容 |

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 消息已入队 |
| 400 | 请求体 JSON 解析失败，或缺少必填字段 |
| 401 | API Key 无效或缺失 |

**示例:**

```bash
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "What is the weather today?"}'
```

---

### GET `/sessions`

获取所有会话的详细信息列表。

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
    }
  }
]
```

**响应字段:**

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 会话 ID（格式: `YYYY-MM-DD-HH-MM-SS`） |
| `title` | string | 会话标题（自动从首条用户消息提取，最多 50 字） |
| `cwd` | string | 会话工作目录 |
| `provider` | string | Provider 名称 |
| `model` | string | 模型名称 |
| `pin` | boolean | 是否置顶 |
| `in_progress` | boolean | 是否正在生成中 |
| `message_count` | number | 消息总数 |
| `last_message` | object\|null | 最后一条消息对象（无消息时为 null） |

**`last_message` 对象:**

| 字段 | 类型 | 说明 |
|---|---|---|
| `role` | string | 消息角色（`user` / `assistant`） |
| `content` | string | 消息内容（截断至 100 字符） |
| `created` | number | 消息创建时的 Unix 时间戳 |

**示例:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions
```

---

### GET `/sessions/{id}`

获取单个会话的详细信息。

**Path 参数:**

| 参数 | 说明 |
|---|---|
| `id` | 会话 ID |

**Response (200 OK):**

返回格式与 `GET /sessions` 的单个元素相同。

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 200 | 成功 |
| 404 | 会话不存在 |

**示例:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions/2024-01-15-10-30-00
```

---

### GET `/sessions/{id}/raw`

获取会话的完整缓存 JSON 文件内容。包含所有消息、元数据、Usage 统计等。

**Path 参数:**

| 参数 | 说明 |
|---|---|
| `id` | 会话 ID |

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 200 | 成功 — 返回原始 JSON |
| 404 | 缓存文件不存在 |
| 500 | 读取缓存文件失败 |

**示例:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions/2024-01-15-10-30-00/raw
```

---

### GET `/providers`

获取所有已注册的 Provider 及其可用模型列表。

**Response (200 OK):**

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

**响应字段:**

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | string | Provider 名称（如 `openai`, `anthropic`） |
| `models` | string[] | 可用模型列表（来自 `available_models()` 方法） |

**示例:**

```bash
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers
```

---

### GET `/messages`

获取指定会话的消息列表，支持分页。

**Query 参数:**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `session` | string | 是 | 会话 ID |
| `since` | number | 否 | 从第 N 条消息开始（1-indexed） |

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

**消息对象字段:**

| 字段 | 类型 | 说明 |
|---|---|---|
| `role` | string | 角色: `user` / `assistant` / `tool` / `system` |
| `content` | string\|null | 消息内容（tool call 消息可能为 null） |
| `reasoning_content` | string\|null | 推理内容（thinking 模型） |
| `tool_calls` | array\|null | 助手发出的 tool call |
| `tool_call_id` | string\|null | Tool call ID（tool 角色的消息） |
| `created` | number\|null | Unix 时间戳 |
| `usage` | object\|null | Token 用量统计（`total_tokens`, `prompt_tokens`, `completion_tokens`） |
| `error` | string\|null | 请求失败时的错误信息 |
| `tool_call_state` | string\|null | Tool call 执行状态 |

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 200 | 成功 |
| 400 | 缺少 `session` 参数 |
| 404 | 会话不存在 |

**示例:**

```bash
# 获取所有消息
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00" \
  -H "X-API-Key: your-secret-key"

# 从第 5 条消息开始
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00&since=5" \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/new`

创建新的会话，可选择指定 Provider 和模型。

**Request Body**（可选）:

```json
{
  "provider": "openai",
  "model": "gpt-4o"
}
```

**参数:**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `provider` | string | 否 | 指定 Provider |
| `model` | string | 否 | 指定模型 |

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

**响应字段:**

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 新创建的会话 ID |
| `title` | string | 会话标题（新会话为空） |
| `cwd` | string | 当前工作目录 |
| `provider` | string | Provider 名称 |
| `model` | string | 模型名称 |
| `in_progress` | boolean | 生成状态（新会话为 false） |
| `message_count` | number | 消息数（新会话为 0） |
| `last_message` | null | 最后消息（新会话为 null） |

**示例:**

```bash
# 使用默认 Provider/模型
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key"

# 指定 Provider/模型
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "openai", "model": "gpt-4o"}'
```

---

### DELETE `/session/{id}`

删除指定会话。

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 会话已删除 |
| 404 | 会话不存在 |
| 409 | 会话正在生成中，无法删除 |

**示例:**

```bash
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/{id}/stop`

停止指定会话的生成。

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 已取消生成 |
| 404 | 会话不存在 |

**示例:**

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/stop \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/{id}/clear`

清空指定会话的所有消息和 Usage 统计。

> 注意：会话本身不会被删除，仅重置消息内容和统计数据。

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 会话已清空 |
| 404 | 会话不存在 |
| 409 | 会话正在生成中，无法清空 |
| 500 | 清空失败 |

**示例:**

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/clear \
  -H "X-API-Key: your-secret-key"
```

---

### POST `/session/{id}/retry`

重试最后一条消息。将重新发送最后一条用户消息给 AI。

> 注意：仅在最后一条消息**不是** assistant 角色时才能重试。

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 已发起重试 |
| 404 | 会话不存在 |
| 409 | 会话正在生成中，无法重试 |
| 400 | 没有可重试的消息（如无消息或最后一条已是 assistant） |

**示例:**

```bash
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/retry \
  -H "X-API-Key: your-secret-key"
```

---

### PUT `/session/{id}/provider`

设置会话的 Provider。

**Request Body:**

```json
{
  "provider": "anthropic"
}
```

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — Provider 已更新 |
| 404 | 会话不存在 |
| 400 | 缺少或无效的 provider 值 |

**示例:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/provider \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic"}'
```

---

### PUT `/session/{id}/model`

设置会话的模型。

**Request Body:**

```json
{
  "model": "claude-3-5-sonnet-20241022"
}
```

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 模型已更新 |
| 404 | 会话不存在 |
| 400 | 缺少或无效的 model 值 |

**示例:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/model \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet-20241022"}'
```

---

### PUT `/session/{id}/cwd`

设置会话的工作目录。

**Request Body:**

```json
{
  "cwd": "/path/to/project"
}
```

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 工作目录已更新 |
| 404 | 会话不存在 |
| 400 | 缺少或无效的 cwd 值 |

**示例:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/cwd \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"cwd": "/home/user/new-project"}'
```

---

### PUT `/session/{id}/pin`

设置会话的置顶状态。

**Request Body:**

```json
{
  "pin": true
}
```

**参数:**

| 参数 | 类型 | 说明 |
|---|---|---|
| `pin` | boolean | 置顶状态（`true` = 置顶，`false` = 取消置顶） |

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 置顶状态已更新 |
| 404 | 会话不存在 |
| 400 | 缺少或无效的 pin 值 |

**示例:**

```bash
# 置顶
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/pin \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"pin": true}'

# 取消置顶
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/pin \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"pin": false}'
```

---

### PUT `/session/{id}/title`

设置会话的自定义标题。

**Request Body:**

```json
{
  "title": "My custom title"
}
```

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 204 | 成功 — 标题已更新 |
| 404 | 会话不存在 |
| 400 | 缺少或无效的 title 值 |

**示例:**

```bash
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/title \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"title": "Debugging Lua plugin"}'
```

---

### GET `/session`

获取会话的 HTML 预览页面（**无需认证**，可直接在浏览器中打开）。

**Query 参数:**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | 是 | 会话 ID |

**响应状态码:**

| 状态码 | 说明 |
|---|---|
| 200 | 成功 — 返回 HTML 内容 |
| 400 | 缺少 `id` 参数 |
| 404 | 会话不存在 |

**示例:**

```bash
# 命令行
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"

# 浏览器直接打开
# http://127.0.0.1:7777/session?id=2024-01-15-10-30-00
```

---

## 消息队列系统

`POST /` 推送的消息会进入内部队列，由定时器轮询处理，确保消息按序可靠投递。

```
外部应用 → POST / → 消息队列 → 定时器(5秒) → 投递到会话
```

**工作机制:**

1. 消息立即入队
2. 定时器每 5 秒检查一次队列
3. 当会话空闲时（`in_progress` 为 false），按 FIFO 顺序投递消息
4. 会话忙碌时，消息留在队列中等待

这样确保消息不会丢失，且按发送顺序被处理。

---

## 通用响应状态码

以下状态码在所有端点中通用：

| 状态码 | 说明 |
|---|---|
| 200 | 成功 — 返回 JSON 数据 |
| 204 | 成功 — 无返回内容 |
| 400 | 请求格式错误（JSON 解析失败、缺少参数等） |
| 401 | API Key 无效或缺失 |
| 404 | 资源不存在或方法/路径错误 |

---

## 使用示例

### curl

```bash
# 发送消息
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"session": "2024-01-15-10-30-00", "content": "Hello from curl!"}'

# 获取会话列表
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/sessions

# 获取 Provider 列表
curl -H "X-API-Key: your-secret-key" http://127.0.0.1:7777/providers

# 创建新会话
curl -X POST http://127.0.0.1:7777/session/new \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "openai", "model": "gpt-4o"}'

# 设置 Provider
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/provider \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"provider": "anthropic"}'

# 设置模型
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/model \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3-5-sonnet-20241022"}'

# 设置工作目录
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/cwd \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"cwd": "/home/user/project"}'

# 置顶会话
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/pin \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"pin": true}'

# 设置标题
curl -X PUT http://127.0.0.1:7777/session/2024-01-15-10-30-00/title \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"title": "My custom title"}'

# 删除会话
curl -X DELETE http://127.0.0.1:7777/session/2024-01-15-10-30-00 \
  -H "X-API-Key: your-secret-key"

# 停止生成
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/stop \
  -H "X-API-Key: your-secret-key"

# 清空消息
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/clear \
  -H "X-API-Key: your-secret-key"

# 重试
curl -X POST http://127.0.0.1:7777/session/2024-01-15-10-30-00/retry \
  -H "X-API-Key: your-secret-key"

# 获取消息（带分页）
curl "http://127.0.0.1:7777/messages?session=2024-01-15-10-30-00&since=5" \
  -H "X-API-Key: your-secret-key"

# 获取原始缓存
curl "http://127.0.0.1:7777/sessions/2024-01-15-10-30-00/raw" \
  -H "X-API-Key: your-secret-key"

# 获取 HTML 预览（无需 Key）
curl "http://127.0.0.1:7777/session?id=2024-01-15-10-30-00"
```

### Python

```python
import requests

BASE_URL = "http://127.0.0.1:7777"
HEADERS = {"X-API-Key": "your-secret-key"}


# 发送消息
def send_message(session_id: str, content: str) -> bool:
    resp = requests.post(
        f"{BASE_URL}/",
        json={"session": session_id, "content": content},
        headers=HEADERS,
    )
    return resp.status_code == 204


# 获取会话列表
def list_sessions() -> list:
    resp = requests.get(f"{BASE_URL}/sessions", headers=HEADERS)
    return resp.json() if resp.status_code == 200 else []


# 获取 Provider 列表
def list_providers() -> list:
    resp = requests.get(f"{BASE_URL}/providers", headers=HEADERS)
    return resp.json() if resp.status_code == 200 else []


# 创建新会话
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


# 获取消息
def get_messages(session_id: str, since: int = None) -> list:
    params = {"session": session_id}
    if since:
        params["since"] = since
    resp = requests.get(f"{BASE_URL}/messages", params=params, headers=HEADERS)
    return resp.json() if resp.status_code == 200 else []


# 删除会话
def delete_session(session_id: str) -> bool:
    resp = requests.delete(f"{BASE_URL}/session/{session_id}", headers=HEADERS)
    return resp.status_code == 204


# 使用示例
if __name__ == "__main__":
    # 创建新会话
    session_id = create_session(provider="openai", model="gpt-4o")
    if session_id:
        print(f"Created session: {session_id}")

        # 发送消息
        send_message(session_id, "Hello from Python!")

        # 列出所有会话
        for s in list_sessions():
            print(f"Session: {s['id']}, Provider: {s['provider']}, Messages: {s['message_count']}")
```

### JavaScript / Node.js

```javascript
const BASE_URL = "http://127.0.0.1:7777";
const HEADERS = { "X-API-Key": "your-secret-key" };

// 发送消息
async function sendMessage(sessionId, content) {
  const resp = await fetch(`${BASE_URL}/`, {
    method: "POST",
    headers: { ...HEADERS, "Content-Type": "application/json" },
    body: JSON.stringify({ session: sessionId, content }),
  });
  return resp.status === 204;
}

// 获取会话列表
async function listSessions() {
  const resp = await fetch(`${BASE_URL}/sessions`, { headers: HEADERS });
  return resp.ok ? resp.json() : [];
}

// 获取 Provider 列表
async function listProviders() {
  const resp = await fetch(`${BASE_URL}/providers`, { headers: HEADERS });
  return resp.ok ? resp.json() : [];
}

// 创建新会话
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

// 获取消息
async function getMessages(sessionId, since) {
  const params = new URLSearchParams({ session: sessionId });
  if (since) params.set("since", since);

  const resp = await fetch(`${BASE_URL}/messages?${params}`, { headers: HEADERS });
  return resp.ok ? resp.json() : [];
}

// 使用示例
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

## 安全注意事项

> ⚠️ **重要安全说明**

1. **API Key 保护**: 使用强密钥（建议 `openssl rand -hex 32` 生成），切勿提交到版本控制
2. **网络隔离**: 默认绑定 `127.0.0.1`，仅本地可访问。如需暴露到外网，请务必使用 HTTPS 反向代理
3. **输入验证**: 所有请求体都经过 JSON 解析和字段类型校验
4. **速率限制**: 如有需要，请在外部自行实现限流

---

## 集成场景

### CI/CD 流水线

```bash
# 在构建脚本中发送通知
curl -X POST http://127.0.0.1:7777/ \
  -H "X-API-Key: your-secret-key" \
  -H "Content-Type: application/json" \
  -d "{\"session\": \"$SESSION_ID\", \"content\": \"Build #$BUILD_NUMBER completed: $STATUS\"}"
```

### 监控仪表盘

```javascript
// Web 仪表盘显示 Provider 列表
async function updateDashboard() {
  const resp = await fetch("http://127.0.0.1:7777/providers", {
    headers: { "X-API-Key": "your-secret-key" },
  });
  const providers = await resp.json();

  document.getElementById("provider-list").innerHTML = providers
    .map((p) => `<li>${p.name} — ${p.models.length} models</li>`)
    .join("");
}
```

---

## 参考

- [Providers](../providers/) — AI Provider 配置
- [Tools](../tools/) — 工具系统
- [Memory System](../memory/) — 记忆系统
- [IM Integration](../integrations/im/) — 即时通讯集成


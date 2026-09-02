---
layout: default
title: Providers
nav_order: 4
has_children: false
---

<!-- prettier-ignore-start -->
# Providers
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

chat.nvim uses a two-layer architecture for AI service integration:

- **Providers**: Handle HTTP requests to specific AI services (DeepSeek, OpenAI, GitHub, etc.)
- **Protocols**: Parse API responses from different AI services (OpenAI, Anthropic, etc.)

Most AI services use OpenAI-compatible APIs, so the default protocol is `openai`. Providers can specify a custom protocol via the `protocol` field if needed.

---

## Built-in Providers

chat.nvim comes with built-in support for 19+ AI providers:

### 1. DeepSeek

[DeepSeek AI](https://platform.deepseek.com/)

```lua
provider = 'deepseek'
model = 'deepseek-v4-pro'  -- or 'deepseek-v4-flash'
```

**Available Models:**

- `deepseek-v4-pro` - Most capable model, supports thinking mode
- `deepseek-v4-flash` - Fast model

{: .info }

> DeepSeek API supports `thinking.type = 'enabled'` for reasoning mode.

### 2. GitHub AI

[GitHub AI](https://github.com/features/ai)

```lua
provider = 'github'
model = 'gpt-4o'  -- or other GitHub models
```

**Configuration:**

```lua
api_key = {
  github = 'github_pat_xxxxxxxx',  -- GitHub Personal Access Token
}
```

### 3. Moonshot

[Moonshot AI](https://platform.moonshot.cn/)

```lua
provider = 'moonshot'
model = 'moonshot-v1-8k'
```

**Available Models:**

- `moonshot-v1-8k` - 8K context window
- `moonshot-v1-32k` - 32K context window
- `moonshot-v1-128k` - 128K context window

### 4. OpenRouter

[OpenRouter](https://openrouter.ai/)

```lua
provider = 'openrouter'
model = 'openai/gpt-4-turbo'  -- Access multiple models through OpenRouter
```

**Configuration:**

```lua
api_key = {
  openrouter = 'sk-or-xxxxxxxx',
}
```

### 5. Qwen (Alibaba Cloud)

[Alibaba Cloud Qwen](https://www.aliyun.com/product/bailian)

```lua
provider = 'qwen'
model = 'qwen-turbo'
```

**Available Models:**

- `qwen-turbo` - Fast model
- `qwen-plus` - Balanced model
- `qwen-max` - Most capable model

### 6. SiliconFlow

[SiliconFlow](https://www.siliconflow.cn/)

```lua
provider = 'siliconflow'
model = 'Qwen/Qwen2.5-7B-Instruct'
```

**Configuration:**

```lua
api_key = {
  siliconflow = 'xxxxxxxx-xxxx-xxxx',
}
```

### 7. Tencent Hunyuan

[Tencent Hunyuan](https://cloud.tencent.com/document/product/1729)

```lua
provider = 'tencent'
model = 'hunyuan-lite'
```

**Available Models:**

- `hunyuan-lite` - Lite version
- `hunyuan-standard` - Standard version
- `hunyuan-pro` - Pro version

### 8. BigModel

[BigModel AI](https://bigmodel.cn/)

```lua
provider = 'bigmodel'
model = 'glm-4'
```

**Configuration:**

```lua
api_key = {
  bigmodel = 'xxxxxxxx-xxxx-xxxx',
}
```

### 9. Volcengine

[Volcengine AI](https://console.volcengine.com)

```lua
provider = 'volcengine'
model = 'doubao-pro-4k'
```

**Configuration:**

```lua
api_key = {
  volcengine = 'xxxxxxxx-xxxx-xxxx',
}
```

### 10. OpenAI

[OpenAI](https://developers.openai.com/api/docs/)

```lua
provider = 'openai'
model = 'gpt-4o'  -- or 'gpt-4-turbo', 'gpt-3.5-turbo'
```

**Available Models:**

- `gpt-4o` - Latest GPT-4 Omni
- `gpt-4-turbo` - GPT-4 Turbo
- `gpt-3.5-turbo` - GPT-3.5 Turbo

### 11. Anthropic Claude

[Anthropic Claude](https://www.anthropic.com/)

```lua
provider = 'anthropic'
model = 'claude-3-5-sonnet-20241022'
```

**Available Models:**

- `claude-3-5-sonnet-20241022` - Latest Claude 3.5 Sonnet
- `claude-3-opus-20240229` - Claude 3 Opus
- `claude-3-haiku-20240307` - Claude 3 Haiku

{: .warning }

> Anthropic uses a different protocol (`anthropic`) instead of the default OpenAI protocol.

### 12. Google Gemini

[Google Gemini](https://ai.google.dev/)

```lua
provider = 'gemini'
model = 'gemini-1.5-flash'
```

**Available Models:**

- `gemini-1.5-flash` - Fast model
- `gemini-1.5-pro` - Most capable model

{: .warning }

> Gemini uses a different protocol (`gemini`) instead of the default OpenAI protocol.

### 13. Ollama

[Ollama](https://ollama.ai/)

```lua
provider = 'ollama'
model = 'llama2'  -- or any locally installed model
```

**Setup:**

1. Install Ollama: https://ollama.ai/
2. Pull a model: `ollama pull llama2`
3. Ollama runs locally, no API key required

### 14. LongCat

[LongCat AI](https://longcat.chat/platform/docs/)

```lua
provider = 'longcat'
model = 'longcat-chat'
```

**Configuration:**

```lua
api_key = {
  longcat = 'lc-xxxxxxxxxxxx',
}
```

### 15. CherryIN

[CherryIN AI](https://open.cherryin.ai/)

```lua
provider = 'cherryin'
model = 'cherryin-chat'
```

**Configuration:**

```lua
api_key = {
  cherryin = 'sk-xxxxxxxxxxxx',
}
```

### 16. Yuanjing

[Yuanjing AI](https://maas.ai-yuanjing.com/)

```lua
provider = 'yuanjing'
model = 'yuanjing-chat'
```

### 17. Baidu Qianfan

[Baidu Qianfan](https://qianfan.baidubce.com/)

```lua
provider = 'baidu'
model = 'ernie-4.0-8k'  -- or other Baidu models
```

**Configuration:**

```lua
api_key = {
  baidu = 'xxxxxxxx-xxxx-xxxx',
}
```

**Notes:**

- Available models are dynamically fetched from the Baidu Qianfan API
- Supports streaming and thinking mode (`enable_thinking`)

### 18. Xiaomi MiMo

[Xiaomi MiMo](https://www.xiaomimimo.com/)

```lua
provider = 'xiaomi'
model = 'mimo-v2.5-pro'
```

**Available Models:**

- `mimo-v2.5-pro` - Most capable model
- `mimo-v2.5` - General purpose
- `mimo-v2.5-tts` - Text-to-speech
- `mimo-v2-pro` - Pro version
- `mimo-v2-omni` - Omni model
- `mimo-v2-flash` - Fast model

**Configuration:**

```lua
api_key = {
  xiaomi = 'xxxxxxxx-xxxx-xxxx',
}
```

**Notes:**

- Supports thinking mode (`thinking.type = 'enabled'`)

### 19. Alibaba Cloud (Bailian/DashScope)

[Alibaba Cloud Bailian](https://www.aliyun.com/product/bailian)

```lua
provider = 'aliyuncs'
model = 'qwen-plus'  -- or other DashScope models
```

**Configuration:**

```lua
api_key = {
  aliyuncs = 'sk-xxxxxxxxxxxx',
}
```

**Notes:**

- Available models are dynamically fetched from the DashScope API
- Uses OpenAI-compatible API endpoint (`dashscope.aliyuncs.com/compatible-mode/v1/`)
- Supports streaming and thinking mode (`enable_thinking`)

---

## Provider Selection

### Using Configuration

Set default provider in your configuration:

```lua
require('chat').setup({
  provider = 'deepseek',
  model = 'deepseek-v4-pro',
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
  },
})
```

### Using Picker

Switch providers dynamically using the picker:

```vim
:Picker chat_provider
" or use the keybinding
<Leader>fp
```

### Using Model Picker

Select a model for the current provider:

```vim
:Picker chat_model
" or use the keybinding
<Leader>fm
```

---

## Protocols

Protocols handle parsing of API responses. chat.nvim supports multiple protocols:

### OpenAI Protocol (Default)

Most AI services use OpenAI-compatible API format. This is the default protocol for all built-in providers.

**Response Format:**

```json
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Response text"
      }
    }
  ]
}
```

### Anthropic Protocol

Used by Anthropic Claude. The `anthropic` provider automatically uses this protocol.

**Response Format:**

```json
{
  "content": [
    {
      "type": "text",
      "text": "Response text"
    }
  ]
}
```

### Gemini Protocol

Used by Google Gemini. The `gemini` provider automatically uses this protocol.

**Response Format:**

```json
{
  "candidates": [
    {
      "content": {
        "parts": [
          {
            "text": "Response text"
          }
        ]
      }
    }
  ]
}
```

---

## Custom Providers

You can create custom providers for AI services not in the built-in list.

### Creating a Custom Provider

Create a file at `~/.config/nvim/lua/chat/providers/<provider_name>.lua`:

```lua
-- ~/.config/nvim/lua/chat/providers/my_provider.lua
local M = {}
local job = require('job')
local curl = require('chat.curl')
local sessions = require('chat.sessions')
local config = require('chat.config')

function M.available_models()
  return {
    'model-1',
    'model-2',
    'model-3',
  }
end

function M.request(opt)
  local body = vim.json.encode({
    model = sessions.get_session_model(opt.session),
    messages = opt.messages,
    stream = true,
    stream_options = { include_usage = true },
    tools = require('chat.tools').request_tools(opt.session),
  })

  local cmd = curl.build_request({
    url = 'https://api.example.com/v1/chat/completions',
    method = 'POST',
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. config.config.api_key.my_provider,
    },
    stdin_body = true,
  })

  local jobid = job.start(cmd, {
    on_stdout = opt.on_stdout,
    on_stderr = opt.on_stderr,
    on_exit = opt.on_exit,
  })
  job.send(jobid, body)
  job.send(jobid, nil)
  sessions.set_session_jobid(opt.session, jobid)

  return jobid
end

-- Optional: specify custom protocol (defaults to 'openai')
-- M.protocol = 'anthropic'

return M
```

### Required Functions

A provider module must implement:

1. **`available_models()`** - Return a list of available model names
2. **`request(opt)`** - Send HTTP request and return job ID

### Optional Fields

- **`protocol`** - Specify which protocol to use (default: `openai`)

### Using Custom Provider

After creating the provider file, configure it in your setup:

```lua
require('chat').setup({
  provider = 'my_provider',
  model = 'model-1',
  api_key = {
    my_provider = 'your-api-key-here',
  },
})
```

---

## Custom Protocols

If you need a custom protocol, create a file at `~/.config/nvim/lua/chat/protocol/<protocol_name>.lua`:

```lua
-- ~/.config/nvim/lua/chat/protocol/my_protocol.lua
local M = {}

local log = require('chat.log')
local sessions = require('chat.sessions')

local sse_buffers = {}

function M.on_stdout(id, data)
  vim.schedule(function()
    for _, line in ipairs(data) do
      if vim.startswith(line, 'data:') then
        local v = line:sub(6)
        if v:sub(1, 1) == ' ' then
          v = v:sub(2)
        end
        table.insert(sse_buffers, v)
      elseif line == '' then
        if #sse_buffers > 0 then
          local text = table.concat(sse_buffers, '\n')
          sse_buffers = {}
          if vim.trim(text) ~= '[DONE]' then
            local ok, chunk = pcall(vim.json.decode, text)
            if ok and chunk and chunk.choices and #chunk.choices > 0 then
              local choice = chunk.choices[1]
              if choice.delta and choice.delta.content then
                -- Stream content to the session
                sessions.on_progress(id, choice.delta.content)
              end
              if chunk.usage then
                sessions.set_progress_usage(id, chunk.usage)
              end
            end
          end
        end
      end
    end
  end)
end

function M.on_stderr(id, data)
  vim.schedule(function()
    for _, line in ipairs(data) do
      log.debug(string.format('jobid %d, stderr %s', id, line))
    end
  end)
end

function M.on_exit(id, code, signal)
  vim.schedule(function()
    local session = sessions.get_progress_session(id)
    if code == 0 and signal == 0 then
      sessions.on_progress_done(id)
      if session then
        sessions.on_complete(session, id)
      end
    end
    sessions.on_progress_exit(id, code, signal)
  end)
end

return M
```

### Protocol Functions

| Function                  | Description                                    |
| ------------------------- | ---------------------------------------------- |
| `on_stdout(id, data)`     | Handle stdout data from curl (SSE stream lines) |
| `on_stderr(id, data)`     | Handle stderr data                             |
| `on_exit(id, code, signal)` | Handle request completion                     |

### Key Session API Calls

Within protocol functions, use these `sessions` module functions:

| Function                                  | Description                                          |
| ----------------------------------------- | ---------------------------------------------------- |
| `sessions.on_progress(id, content)`       | Stream a text chunk to the UI                        |
| `sessions.on_progress_tool_call(id, tc)`  | Handle a tool call delta                             |
| `sessions.on_progress_done(id)`           | Mark the stream as done                              |
| `sessions.on_complete(session, id)`       | Trigger post-completion logic (e.g. tool results)    |
| `sessions.on_progress_exit(id, code, sig)`| Clean up progress state on exit                      |
| `sessions.get_progress_session(id)`       | Get the session object from job ID                   |
| `sessions.set_progress_usage(id, usage)`  | Set token usage for the request                      |

See `lua/chat/protocol/openai.lua` for reference implementation.

---

## API Key Configuration

### Single Provider

```lua
require('chat').setup({
  provider = 'deepseek',
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
  },
})
```

### Multiple Providers

```lua
require('chat').setup({
  provider = 'deepseek',  -- Default provider
  api_key = {
    deepseek = 'sk-xxxxxxxxxxxx',
    github = 'github_pat_xxxxxxxx',
    openai = 'sk-xxxxxxxxxxxx',
    anthropic = 'sk-ant-xxxxxxxxxxxx',
  },
})
```

### Environment Variables

You can also use environment variables:

```lua
require('chat').setup({
  api_key = {
    deepseek = os.getenv('DEEPSEEK_API_KEY'),
    openai = os.getenv('OPENAI_API_KEY'),
  },
})
```

---

## Switching Providers

### Method 1: Configuration

Change the default provider in configuration:

```lua
require('chat').setup({
  provider = 'openai',
  model = 'gpt-4o',
})
```

### Method 2: Picker

Use the picker to switch providers interactively:

```vim
:Picker chat_provider
```

Select the provider you want to use, and it will be applied to the current session.

### Method 3: Model Picker

Use the model picker to select a model for the current provider:

```vim
:Picker chat_model
```

This will show all available models for the current provider.

---

## Provider-Specific Notes

### DeepSeek

- **Default model**: `deepseek-v4-pro`
- **API Base**: `https://api.deepseek.com`
- **Supports**: Streaming, function calling, thinking mode

### OpenAI

- **Default model**: `gpt-4o`
- **API Base**: `https://api.openai.com`
- **Supports**: Streaming, function calling, vision

### Anthropic

- **Default model**: `claude-3-5-sonnet-20241022`
- **API Base**: `https://api.anthropic.com`
- **Protocol**: Uses `anthropic` protocol (not OpenAI-compatible)
- **Supports**: Streaming, function calling

### Google Gemini

- **Default model**: `gemini-1.5-flash`
- **API Base**: `https://generativelanguage.googleapis.com`
- **Protocol**: Uses `gemini` protocol (not OpenAI-compatible)
- **Supports**: Streaming, function calling, vision

### Ollama

- **Default model**: `llama2`
- **API Base**: `http://localhost:11434`
- **No API key required**: Runs locally
- **Supports**: Streaming, function calling

---

## Troubleshooting

### API Key Issues

{: .warning }

> Make sure your API key is correct and has the necessary permissions.

**Test your API key:**

```bash
# DeepSeek
curl https://api.deepseek.com/v1/models \
  -H "Authorization: Bearer sk-xxxxxxxxxxxx"

# OpenAI
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer sk-xxxxxxxxxxxx"
```

### Provider Not Found

If you get "Provider not found" error:

1. Check the provider name is correct
2. Ensure the provider file exists in `lua/chat/providers/`
3. Verify the provider module returns the correct functions

### Protocol Errors

If you get protocol-related errors:

1. Check if the provider uses a custom protocol
2. Ensure the protocol file exists in `lua/chat/protocol/`
3. Verify the protocol module implements all required functions

---

## Next Steps

- [Tools](./tools/) - Explore available tools
- [Usage](./usage/) - Learn how to use chat.nvim
- [Memory System](./memory/) - Learn about the memory system


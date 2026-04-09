---
layout: default
title: MCP (Model Context Protocol)
nav_order: 7
has_children: false
parent: Using chat.nvim
---

# MCP (Model Context Protocol)

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

chat.nvim supports Model Context Protocol (MCP) servers for extended tool capabilities. MCP allows you to connect external tool servers that provide additional functionality.

## Overview

MCP is a protocol that enables AI assistants to interact with external tools and services in a standardized way. chat.nvim provides native integration with MCP servers, allowing you to:

- Connect to multiple MCP servers simultaneously
- Use MCP tools alongside built-in tools
- Discover and call MCP tools seamlessly
- Support both stdio and HTTP transports

{: .info }
> MCP tools are automatically discovered and integrated when MCP servers are configured. They follow the naming pattern `mcp_<server>_<tool>`.

---

## Supported Transports

### stdio Transport

Standard input/output transport (default for command-based servers).

**Use case**: Local MCP servers that run as command-line processes.

**Example configuration**:

```lua
mcp = {
  open_webSearch = {
    command = 'npx',
    args = { '-y', 'open-websearch@latest' },
  },
}
```

### streamable_http Transport

HTTP transport with SSE support (for HTTP-based servers).

**Use case**: Remote MCP servers or HTTP-based services.

**Example configuration**:

```lua
mcp = {
  my_http_server = {
    url = 'https://mcp-server.example.com',
    headers = {
      ['Authorization'] = 'Bearer YOUR_TOKEN',
    },
  },
}
```

---

## Configuration

### Basic Configuration (stdio)

```lua
require('chat').setup({
  mcp = {
    -- Example: Web search MCP server using stdio transport
    open_webSearch = {
      command = 'npx',
      args = { '-y', 'open-websearch@latest' },
      disabled = false,  -- Set to true to disable this server
    },

    -- Example: Another stdio MCP server
    my_custom_server = {
      command = '/path/to/mcp-server',
      args = { '--config', '/path/to/config.json' },
    },
  },
})
```

### HTTP Transport Configuration

For HTTP-based MCP servers:

```lua
require('chat').setup({
  mcp = {
    -- HTTP-based MCP server
    my_http_server = {
      url = 'https://mcp-server.example.com',
      headers = {
        ['Authorization'] = 'Bearer YOUR_TOKEN',
      },
    },

    -- HTTP server with command to start
    my_managed_http_server = {
      command = 'my-mcp-http-server',
      args = { '--port', '8080' },
      url = 'http://localhost:8080',
      transport = {
        type = 'streamable_http',
        url = 'http://localhost:8080',
      },
    },
  },
})
```

---

## Transport Parameters

| Parameter           | Type    | Required | Description                                           |
| ------------------- | ------- | -------- | ----------------------------------------------------- |
| `command`           | string  | ❌ No\*  | Path to MCP server executable (required for stdio)    |
| `args`              | array   | ❌ No    | Command-line arguments for the server                 |
| `url`               | string  | ❌ No\*  | HTTP URL for streamable_http transport                |
| `headers`           | table   | ❌ No    | HTTP headers (key-value pairs)                        |
| `transport`         | table   | ❌ No    | Explicit transport configuration                      |
| `transport.type`    | string  | ❌ No    | Transport type: `"stdio"` or `"streamable_http"`      |
| `transport.url`     | string  | ❌ No    | Override URL for transport                            |
| `transport.headers` | table   | ❌ No    | Override headers for transport                        |
| `disabled`          | boolean | ❌ No    | Set to `true` to disable this server (default: false) |

\*Either `command` (for stdio) or `url` (for HTTP) is required.

---

## Complete Example

```lua
require('chat').setup({
  -- ... other configuration

  -- MCP servers configuration
  mcp = {
    -- Stdio-based MCP server
    open_webSearch = {
      command = 'npx',
      args = { '-y', 'open-websearch@latest' },
    },

    -- HTTP-based MCP server
    remote_tools = {
      url = 'https://mcp-api.example.com',
      headers = {
        ['Authorization'] = 'Bearer YOUR_API_KEY',
      },
    },

    -- Managed HTTP server (starts local process)
    local_http_server = {
      command = 'my-mcp-server',
      args = { '--port', '3000' },
      transport = {
        type = 'streamable_http',
        url = 'http://localhost:3000',
      },
    },

    -- Disabled server (won't start)
    experimental = {
      command = 'mcp-experimental',
      disabled = true,
    },
  },
})
```

---

## MCP Tool Naming

MCP tools are automatically prefixed with `mcp_<server>_<tool>` format:

- Original MCP tool: `search`
- MCP server name: `open_webSearch`
- Final tool name: `mcp_open_webSearch_search`

---

## Using MCP Tools

### In Chat

MCP tools work exactly like built-in tools:

```
@mcp_open_webSearch_search query="neovim plugins" limit=10
```

```
@mcp_open_webSearch_fetchGithubReadme url="https://github.com/wsdjeg/chat.nvim"
```

### Example MCP Tools

Common MCP tools from the `open_webSearch` server:

- `mcp_open_webSearch_search` - Web search via MCP server
- `mcp_open_webSearch_fetchGithubReadme` - Fetch GitHub README
- `mcp_open_webSearch_fetchCsdnArticle` - Fetch CSDN article
- `mcp_open_webSearch_fetchJuejinArticle` - Fetch Juejin article
- `mcp_open_webSearch_fetchLinuxDoArticle` - Fetch Linux.do article
- `mcp_open_webSearch_fetchWebContent` - Fetch web content

---

## Transport Detection

chat.nvim automatically detects the transport type:

{: .highlight }
1. If `transport.type` is specified, use that transport
2. If `command` exists without `transport`, use **stdio** transport
3. If `url` exists without `command`, use **streamable_http** transport

---

## Server Management

### Commands

Manage MCP servers with these commands:

**Stop MCP servers**:

```vim
:Chat mcp stop
```

Stops all running MCP servers and cleans up resources.

**Start MCP servers**:

```vim
:Chat mcp start
```

Starts all configured MCP servers. Note: Servers are automatically started when opening the chat window.

**Restart MCP servers**:

```vim
:Chat mcp restart
```

Restarts all MCP servers (stops and starts with a delay for cleanup).

### Automatic Management

{: .info }
> - MCP servers are automatically started when opening the chat window (`:Chat`)
> - MCP servers are automatically stopped when you exit Neovim
> - Use the commands above for manual control if needed (e.g., after changing configuration)

---

## Key Features

- **Multiple Transports**: Support for stdio and HTTP transports
- **Automatic Discovery**: MCP tools are automatically discovered and integrated
- **Seamless Integration**: MCP tools work alongside built-in tools
- **Async Execution**: All MCP tool calls are non-blocking
- **Protocol Compliance**: Full JSON-RPC 2.0 protocol support
- **Error Handling**: Graceful error handling and timeout protection
- **Auto Management**: Servers are automatically started when opening chat and stopped on exit

---

## Troubleshooting

### Server Not Starting

**Symptom**: MCP server fails to start.

**Solution**:
1. Verify the `command` path is correct and executable
2. Check if the server executable exists
3. Verify command-line arguments are correct
4. Check server logs with `:messages`

### Tools Not Appearing

**Symptom**: MCP tools are not available in chat.

**Solution**:
1. Wait a few seconds for the initialization handshake
2. Check if the server is running: `:Chat mcp start`
3. Verify the server is not disabled (`disabled = false`)
4. Check server logs for initialization errors

### Tool Call Failures

**Symptom**: MCP tool calls fail or return errors.

**Solution**:
1. Check server logs for error messages (`:messages`)
2. Verify the tool parameters are correct
3. Check if the server has proper permissions
4. Ensure the server is not overloaded

### Connection Issues

**Symptom**: Cannot connect to MCP server.

**Solution**:
1. Verify the MCP server is properly configured
2. Check network connectivity for HTTP servers
3. Verify authentication headers are correct
4. Ensure the server is running and accessible

### HTTP Transport Issues

**Symptom**: HTTP transport fails to connect.

**Solution**:
1. Check that the URL is accessible
2. Verify headers are correct (especially authentication)
3. Test with a simple HTTP request first
4. Check if the server requires specific headers

---

## Best Practices

### 1. Start with Simple Configuration

Begin with a basic stdio server:

```lua
mcp = {
  open_webSearch = {
    command = 'npx',
    args = { '-y', 'open-websearch@latest' },
  },
}
```

### 2. Verify Server Installation

Ensure the MCP server executable is installed and accessible:

```bash
# Test if the command works
npx -y open-websearch@latest
```

### 3. Check Server Logs

Monitor server logs for debugging:

```vim
:messages
```

### 4. Use Appropriate Transport

Choose the right transport based on your server:

- **stdio**: For local command-line servers
- **streamable_http**: For remote HTTP servers

### 5. Test with Simple Tools

Start with simple MCP tools to verify integration:

```
@mcp_open_webSearch_search query="test" limit=1
```

---

## Additional Resources

- [Model Context Protocol specification](https://modelcontextprotocol.io/)
- [MCP server implementations](https://github.com/modelcontextprotocol)
- [open-websearch MCP server](https://github.com/Aas-ee/open-webSearch)

---

## Next Steps

- [Tools Documentation](/docs/tools/) - Learn about all available tools
- [IM Integration](/docs/integrations/im/) - Instant messaging integrations
- [HTTP API](/docs/api/http/) - HTTP API integration

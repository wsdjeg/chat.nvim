-- lua/chat/preview.lua
local M = {}

local config = require('chat.config')

-- Helper function to escape HTML
local function escape_html(text)
  if not text then
    return ''
  end
  text = tostring(text)
  return text
    :gsub('&', '&amp;')
    :gsub('<', '&lt;')
    :gsub('>', '&gt;')
    :gsub('"', '&quot;')
    :gsub("'", '&#39;')
end

-- Format timestamp
local function format_timestamp(unix_timestamp)
  local ok, result = pcall(function()
    return os.date(config.config.strftime, unix_timestamp)
  end)
  if ok then
    return result
  else
    return tostring(unix_timestamp)
  end
end

-- Generate session header HTML
local function generate_header(session_data)
  return string.format(
    [[
    <div class="session-header">
      <h1>Chat Session</h1>
      <div class="session-meta">
        <div class="meta-item">
          <span class="meta-label">Session ID</span>
          <span class="meta-value">%s</span>
        </div>
        <div class="meta-item">
          <span class="meta-label">Provider</span>
          <span class="meta-value">%s</span>
        </div>
        <div class="meta-item">
          <span class="meta-label">Model</span>
          <span class="meta-value">%s</span>
        </div>
        <div class="meta-item">
          <span class="meta-label">Working Directory</span>
          <span class="meta-value">%s</span>
        </div>
        <div class="meta-item meta-item-full">
          <span class="meta-label">System Prompt</span>
          <span class="meta-value meta-value-scrollable">%s</span>
        </div>
      </div>
    </div>
  ]],
    escape_html(session_data.id or 'unknown'),
    escape_html(session_data.provider or 'unknown'),
    escape_html(session_data.model or 'unknown'),
    escape_html(session_data.cwd or ''),
    escape_html(session_data.prompt or '')
  )
end

-- Generate message HTML
local function generate_message(msg)
  local html = '<div class="message">'
  
  -- Message header
  local role_emoji = msg.role == 'user' and '👤' 
    or (msg.role == 'assistant' and '🤖' or '🔧')
  local role_class = 'role-' .. (msg.role or 'unknown')
  
  html = html
    .. '<div class="message-header">'
    .. string.format('<span class="timestamp">[%s]</span>', 
        format_timestamp(msg.created or os.time()))
    .. string.format('<span class="role-badge %s">%s %s</span>', 
        role_class, role_emoji, escape_html(msg.role or 'unknown'))
    .. '</div>'
  
  -- Reasoning content (thinking)
  if msg.reasoning_content and #msg.reasoning_content > 0 then
    html = html
      .. '<div class="reasoning-content">'
      .. escape_html(msg.reasoning_content)
      .. '</div>'
  end
  
  -- Tool calls
  if msg.tool_calls and #msg.tool_calls > 0 then
    html = html .. '<div class="tool-calls">'
    for _, tool_call in ipairs(msg.tool_calls) do
      if tool_call['function'] then
        html = html
          .. '<div class="tool-call">'
          .. string.format(
              '<div class="tool-call-header">Executing tool: <span class="tool-function-name">%s</span></div>',
              escape_html(tool_call['function'].name or 'unknown')
            )
        
        -- Parse and format arguments
        local args_str = tool_call['function'].arguments or ''
        local ok, args = pcall(vim.json.decode, args_str)
        if ok and args then
          local formatted = vim.inspect(args, { indent = '  ', newline = '\n' })
          html = html
            .. '<div class="tool-arguments">'
            .. escape_html(formatted)
            .. '</div>'
        else
          html = html
            .. '<div class="tool-arguments">'
            .. escape_html(args_str)
            .. '</div>'
        end
        html = html .. '</div>'
      end
    end
    html = html .. '</div>'
  end
  
  -- Tool result
  if msg.role == 'tool' then
    if msg.tool_call_state and msg.tool_call_state.error then
      html = html
        .. '<div class="tool-error">'
        .. '<div class="tool-error-header">Tool Error</div>'
        .. string.format('<div>%s</div>', escape_html(msg.tool_call_state.error))
        .. '</div>'
    else
      local tool_name = (msg.tool_call_state and msg.tool_call_state.name) or 'unknown'
      html = html
        .. '<div class="tool-result">'
        .. string.format('<div class="tool-result-header">Tool execution complete: %s</div>', 
            escape_html(tool_name))
        .. string.format('<div class="tool-result-content">%s</div>', 
            escape_html(msg.content or ''))
        .. '</div>'
    end
  end
  
  -- Message content
  if msg.content and msg.role ~= 'tool' then
    html = html
      .. '<div class="message-content">'
      .. escape_html(msg.content)
      .. '</div>'
  end
  
  -- On complete message
  if msg.on_complete then
    html = html .. '<div class="on-complete"><div class="on-complete-header">Completed</div>'
    if msg.usage then
      html = html
        .. string.format(
            '<div class="usage-stats">Tokens: %d (%d↑/%d↓)</div>',
            msg.usage.total_tokens or 0,
            msg.usage.prompt_tokens or 0,
            msg.usage.completion_tokens or 0
          )
    end
    html = html .. '</div>'
  end
  
  -- Error message
  if msg.error then
    html = html
      .. '<div class="error-message">'
      .. string.format('<div>[%s] ❌ : %s</div>', 
          format_timestamp(msg.created or os.time()),
          escape_html(msg.error))
      .. '</div>'
  end
  
  html = html .. '</div>'
  return html
end

-- Generate full HTML page
function M.generate_html(session_data)
  local css = [[
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #1a1a2e;
      color: #e0e0e0;
      padding: 20px;
      line-height: 1.6;
    }
    
    .container {
      max-width: 1200px;
      margin: 0 auto;
    }
    
    .session-header {
      background: #16213e;
      padding: 20px;
      border-radius: 8px;
      margin-bottom: 20px;
      border: 1px solid #0f3460;
    }
    
    .session-header h1 {
      font-size: 24px;
      margin-bottom: 15px;
      color: #e94560;
    }
    
    .session-meta {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 15px;
    }
    
    .meta-item {
      display: flex;
      flex-direction: column;
    }
    
    .meta-item-full {
      grid-column: 1 / -1;
    }
    
    .meta-label {
      font-size: 12px;
      color: #888;
      text-transform: uppercase;
      margin-bottom: 4px;
    }
    
    .meta-value {
      font-size: 16px;
      color: #e0e0e0;
      word-break: break-all;
    }
    
    .meta-value-scrollable {
      max-height: 150px;
      overflow-y: auto;
      background: #1a1a2e;
      padding: 8px;
      border-radius: 4px;
      border: 1px solid #0f3460;
      white-space: pre-wrap;
      font-family: 'Consolas', 'Monaco', monospace;
      font-size: 14px;
    }
    
    .messages {
      background: #16213e;
      border-radius: 8px;
      border: 1px solid #0f3460;
    }
    
    .message {
      padding: 15px 20px;
      border-bottom: 1px solid #0f3460;
    }
    
    .message:last-child {
      border-bottom: none;
    }
    
    .message-header {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 10px;
    }
    
    .timestamp {
      color: #888;
      font-size: 13px;
      font-family: 'Consolas', monospace;
    }
    
    .role-badge {
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 12px;
      font-weight: 600;
    }
    
    .role-user { background: #1f6feb; color: white; }
    .role-assistant { background: #28a745; color: white; }
    .role-tool { background: #f66a0a; color: white; }
    
    .message-content {
      margin-top: 10px;
      white-space: pre-wrap;
      word-wrap: break-word;
    }
    
    .reasoning-content {
      background: #1a1a2e;
      padding: 12px;
      border-left: 3px solid #e94560;
      margin: 10px 0;
      border-radius: 4px;
      color: #b0b0b0;
      font-style: italic;
      white-space: pre-wrap;
      max-height: 300px;
      overflow-y: auto;
    }
    
    .reasoning-content::before {
      content: '💭 Thinking:\A';
      color: #e94560;
      font-weight: bold;
      font-style: normal;
      display: block;
      margin-bottom: 8px;
    }
    
    .tool-calls {
      background: #0f3460;
      padding: 12px;
      border-radius: 4px;
      margin: 10px 0;
    }
    
    .tool-call {
      margin: 8px 0;
    }
    
    .tool-call-header {
      color: #f66a0a;
      font-weight: 600;
      margin-bottom: 5px;
    }
    
    .tool-call-header::before {
      content: '🔧 ';
    }
    
    .tool-function-name {
      color: #e94560;
      font-family: 'Consolas', monospace;
    }
    
    .tool-arguments {
      background: #1a1a2e;
      padding: 8px;
      border-radius: 4px;
      margin-top: 8px;
      font-family: 'Consolas', monospace;
      font-size: 13px;
      color: #4ecdc4;
      white-space: pre-wrap;
      overflow-x: auto;
      max-height: 200px;
      overflow-y: auto;
    }
    
    .tool-result {
      margin-top: 8px;
    }
    
    .tool-result-header {
      color: #28a745;
      font-weight: 600;
    }
    
    .tool-result-header::before {
      content: '✅ ';
    }
    
    .tool-result-content {
      background: #1a1a2e;
      padding: 8px;
      border-radius: 4px;
      margin-top: 8px;
      font-family: 'Consolas', monospace;
      font-size: 13px;
      color: #888;
      white-space: pre-wrap;
      max-height: 300px;
      overflow-y: auto;
      border: 1px solid #0f3460;
    }
    
    .tool-error {
      background: #2d1b1b;
      border-left: 3px solid #e94560;
      padding: 12px;
      margin: 10px 0;
      border-radius: 4px;
    }
    
    .tool-error-header {
      color: #e94560;
      font-weight: 600;
    }
    
    .tool-error-header::before {
      content: '❌ ';
    }
    
    .on-complete {
      background: #162447;
      padding: 12px;
      border-radius: 4px;
      margin-top: 10px;
      border: 1px solid #28a745;
    }
    
    .on-complete-header {
      color: #28a745;
      font-weight: 600;
    }
    
    .on-complete-header::before {
      content: '✅ ';
    }
    
    .usage-stats {
      margin-top: 8px;
      color: #888;
      font-size: 13px;
    }
    
    .usage-stats::before {
      content: '📊 ';
    }
    
    .error-message {
      background: #2d1b1b;
      color: #e94560;
      padding: 12px;
      border-radius: 4px;
      margin: 10px 0;
    }
    
    /* Scrollbar styles */
    .meta-value-scrollable::-webkit-scrollbar,
    .tool-result-content::-webkit-scrollbar,
    .tool-arguments::-webkit-scrollbar,
    .reasoning-content::-webkit-scrollbar {
      width: 8px;
      height: 8px;
    }
    
    .meta-value-scrollable::-webkit-scrollbar-track,
    .tool-result-content::-webkit-scrollbar-track,
    .tool-arguments::-webkit-scrollbar-track,
    .reasoning-content::-webkit-scrollbar-track {
      background: #0f3460;
      border-radius: 4px;
    }
    
    .meta-value-scrollable::-webkit-scrollbar-thumb,
    .tool-result-content::-webkit-scrollbar-thumb,
    .tool-arguments::-webkit-scrollbar-thumb,
    .reasoning-content::-webkit-scrollbar-thumb {
      background: #e94560;
      border-radius: 4px;
    }
    
    .meta-value-scrollable::-webkit-scrollbar-thumb:hover,
    .tool-result-content::-webkit-scrollbar-thumb:hover,
    .tool-arguments::-webkit-scrollbar-thumb:hover,
    .reasoning-content::-webkit-scrollbar-thumb:hover {
      background: #ff6b8a;
    }
  ]]
  
  local html = string.format(
    [[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Chat Session - %s</title>
  <style>%s</style>
</head>
<body>
  <div class="container">
    %s
    <div class="messages">
      %s
    </div>
  </div>
</body>
</html>
  ]],
    escape_html(session_data.id or 'unknown'),
    css,
    generate_header(session_data),
    table.concat(
      vim.tbl_map(generate_message, session_data.messages or {}),
      '\n'
    )
  )
  
  return html
end

return M

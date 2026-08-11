-- Auto-nudge: check workspace and prompt AI to handle uncommitted changes
-- When LLM responds with content only (no tool calls), if the git workspace
-- is dirty, inject a user message prompting the AI to commit/push.
local M = {}

local log = require('chat.log')

-- Track which sessions have been nudged to prevent infinite loops.
-- Reset when user sends a new message.
local nudged = {} ---@type table<string, boolean>

--- Check if git workspace is dirty (has uncommitted changes)
--- @param cwd string The working directory to check
--- @return boolean is_dirty True if workspace has uncommitted changes
--- @return string status_output The git status --short output (empty if clean)
local function check_git_status(cwd)
  local output = vim.fn.system({ 'git', '-C', cwd, 'status', '--short' })
  if vim.v.shell_error ~= 0 then
    return false, ''
  end
  output = vim.trim(output)
  if output == '' then
    return false, ''
  end
  return true, output
end

--- Reset nudge flag for a session.
--- Called when user sends a new message to allow nudging again.
--- @param session_id string The session identifier
function M.reset(session_id)
  nudged[session_id] = nil
end

--- Check workspace and nudge AI if dirty.
--- Called when LLM turn ends with content only (no tool calls).
--- Only nudges once per user turn to prevent infinite loops.
--- @param session_id string The session identifier
function M.nudge_if_dirty(session_id)
  -- Already nudged for this turn, don't nudge again
  if nudged[session_id] then
    return
  end

  local storage = require('chat.sessions.storage')
  local session = storage.sessions[session_id]
  if not session or not session.cwd then
    return
  end

  local is_dirty, status_output = check_git_status(session.cwd)
  if not is_dirty then
    return
  end

  -- Mark as nudged to prevent infinite loop
  nudged[session_id] = true

  -- Build nudge message
  local content = '检测到工作区有未提交的更改，请检查并处理（提交、推送等）：\n```\n'
    .. status_output
    .. '\n```'

  -- Append as user message
  local sessions = require('chat.sessions')
  local msg = {
    role = 'user',
    content = content,
    created = os.time(),
  }
  sessions.append_message(session_id, msg)
  require('chat.windows').on_message(session_id, msg)
  require('chat.sessions.storage').write_cache(session_id)

  -- Trigger new request
  sessions.reset_retry_count(session_id)
  local protocol = require('chat.protocol')
  local jobid = protocol.request({
    session = session_id,
    messages = sessions.get_request_messages(session_id),
  })

  if jobid and jobid > 0 then
    if session_id == require('chat.windows').current_session() then
      require('chat.spinners').start()
    end
  else
    log.error('nudge: failed to start request')
  end
end

return M


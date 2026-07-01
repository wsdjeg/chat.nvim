-- lua/chat/tools/user_profile.lua
-- Tool for managing user profiles (人物画像)

local M = {}

local user = require('chat.user')

--- Handle tool call
--- @param arguments table
--- @param ctx ChatToolContext
--- @return table result { content } or { error }
function M.user_profile(arguments, ctx)
  arguments = arguments or {}
  local action = arguments.action or 'get'
  local user_id = arguments.user_id or user.get_user_id()

  if action == 'get' then
    local profile = user.get_profile(user_id)
    if not profile then
      return {
        content = string.format(
          'No profile found for user "%s". Use action="update" to create one.',
          user_id
        ),
      }
    end
    return {
      content = vim.json.encode({
        user_id = user_id,
        profile = profile,
      }),
    }

  elseif action == 'update' then
    if not arguments.content then
      return { error = '"content" is required for update action.' }
    end
    if type(arguments.content) ~= 'string' then
      return { error = '"content" must be a string.' }
    end
    local ok = user.save_profile(user_id, arguments.content)
    if not ok then
      return { error = 'Failed to save user profile.' }
    end
    return {
      content = string.format(
        'User profile for "%s" has been saved successfully.',
        user_id
      ),
    }

  elseif action == 'list' then
    local profiles = user.list_profiles()
    return {
      content = vim.json.encode({
        count = #profiles,
        profiles = profiles,
      }),
    }

  elseif action == 'delete' then
    local ok = user.delete_profile(user_id)
    if not ok then
      return {
        content = string.format(
          'No profile found for user "%s" to delete.',
          user_id
        ),
      }
    end
    return {
      content = string.format(
        'User profile for "%s" has been deleted.',
        user_id
      ),
    }

  else
    return {
      error = string.format(
        'Unknown action: %s. Must be "get", "update", "list", or "delete".',
        action
      ),
    }
  end
end

--- Get tool schema for LLM
--- @return table Tool schema
function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'user_profile',
      description = [[
Manage user profiles (人物画像) for personalized assistance.

User profiles are stored as markdown files and contain information about users
such as their preferences, skills, background, and working habits.

The LLM should proactively update user profiles when learning new information
about the user during conversations.

ACTIONS:
- get: Read a user profile (default action)
- update: Create or update a user profile (content in markdown format)
- list: List all user profiles
- delete: Delete a user profile

PROFILE FORMAT (markdown):
# User Profile: <id>

## Basic Info
- Name: ...
- Timezone: ...
- Language: ...

## Preferences
- Editor: ...
- Coding style: ...

## Skills
- Languages: ...
- Frameworks: ...

## Notes
- ...

Examples:
- user_profile(action="get") — Get current user's profile
- user_profile(action="update", content="# User Profile: wsdjeg\n\n...") — Update profile
- user_profile(action="list") — List all profiles
- user_profile(action="delete", user_id="temp-user") — Delete a profile
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = { 'get', 'update', 'list', 'delete' },
            description = 'Action to perform (default: "get")',
          },
          user_id = {
            type = 'string',
            description = 'User ID (defaults to current user from config)',
          },
          content = {
            type = 'string',
            description = 'Profile content in markdown format (required for "update" action)',
          },
        },
      },
    },
  }
end

--- Format tool info for display
--- @param action string|table
---@return string Formatted info
function M.info(action, _)
  local arguments = action
  if type(action) == 'string' then
    local ok, decoded = pcall(vim.json.decode, action)
    if ok then
      arguments = decoded
    else
      return 'user_profile'
    end
  end

  local act = arguments.action or 'get'
  local uid = arguments.user_id or ''
  if uid and #uid > 0 then
    return string.format('user_profile(%s, user="%s")', act, uid)
  end
  return string.format('user_profile(%s)', act)
end

return M


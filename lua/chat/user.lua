-- lua/chat/user.lua
-- User profile (人物画像) management for chat.nvim

local M = {}

local config = require('chat.config')
local log = require('chat.log')

--- Get the storage directory for user profiles
--- @return string
local function get_storage_dir()
  local cfg = config.config.user or {}
  return cfg.storage_dir
    or (vim.fn.stdpath('data') .. '/chat.nvim/users/')
end

--- Ensure the storage directory exists
local function ensure_storage_dir()
  local dir = get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
end

--- Sanitize user_id for use as filename
--- Only allows alphanumeric, hyphens, underscores
--- @param user_id string
--- @return string sanitized
local function sanitize_user_id(user_id)
  return user_id:gsub('[^%w%-_]', '-')
end

--- Get the current user ID from config
--- Returns empty string if not configured (no auto-detection)
--- @return string
function M.get_user_id()
  local cfg = config.config.user or {}
  return cfg.id or ''
end

--- Get the file path for a user profile
--- @param user_id string
--- @return string
function M.get_profile_path(user_id)
  return get_storage_dir() .. 'user-' .. sanitize_user_id(user_id) .. '.md'
end

--- Read a user profile
--- @param user_id? string (defaults to current user)
--- @return string|nil profile content (markdown), nil if not found
function M.get_profile(user_id)
  user_id = user_id or M.get_user_id()
  if not user_id or #user_id == 0 then
    return nil
  end
  local path = M.get_profile_path(user_id)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  if not lines or #lines == 0 then
    return nil
  end
  return table.concat(lines, '\n')
end

--- Save (create or update) a user profile
--- @param user_id string
--- @param content string markdown content
--- @return boolean success
function M.save_profile(user_id, content)
  if not user_id or #user_id == 0 then
    return false
  end
  ensure_storage_dir()
  local path = M.get_profile_path(user_id)
  local lines = vim.split(content, '\n')
  local ok = pcall(vim.fn.writefile, lines, path)
  if not ok then
    log.error('Failed to write user profile: ' .. path)
    return false
  end
  return true
end

--- Delete a user profile
--- @param user_id string
--- @return boolean success
function M.delete_profile(user_id)
  if not user_id or #user_id == 0 then
    return false
  end
  local path = M.get_profile_path(user_id)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  vim.fn.delete(path)
  return true
end

--- List all user profile IDs
--- @return table array of { id = string, path = string }
function M.list_profiles()
  ensure_storage_dir()
  local dir = get_storage_dir()
  local profiles = {}
  local files = vim.fn.readdir(dir)
  if not files then
    return profiles
  end
  for _, file in ipairs(files) do
    local id = file:match('^user%-(.+)%.[Mm][Dd]$')
    if id then
      table.insert(profiles, {
        id = id,
        path = dir .. file,
      })
    end
  end
  table.sort(profiles, function(a, b)
    return a.id < b.id
  end)
  return profiles
end

--- Get the user profile as a system message string
--- Returns nil if user profiles are disabled, user ID is empty, or no profile exists
--- @param user_id? string (defaults to current user)
--- @return string|nil
function M.get_profile_system_message(user_id)
  local cfg = config.config.user or {}
  if cfg.enable == false then
    return nil
  end
  user_id = user_id or M.get_user_id()
  if not user_id or #user_id == 0 then
    return nil
  end
  local profile = M.get_profile(user_id)
  if not profile or #profile == 0 then
    return nil
  end
  return string.format(
    '---\n\n# User Profile\n\nThe following is the profile of the current user (%s). Use this information to personalize your responses:\n\n%s',
    user_id,
    profile
  )
end

return M


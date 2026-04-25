-- Session management main module
-- All public APIs remain unchanged
local M = {}

local core = require('chat.sessions.core')
local messages = require('chat.sessions.messages')
local progress = require('chat.sessions.progress')
local tools = require('chat.sessions.tools')
local async = require('chat.sessions.async')
local storage = require('chat.sessions.storage')
local share = require('chat.sessions.share')

-- ─── Session CRUD ──────────────────────────────────────────────
M.new = core.new
M.delete = core.delete
-- ─── Session CRUD ──────────────────────────────────────────────
M.new = core.new
M.delete = core.delete
M.previous = core.previous
M.next = core.next
M.exists = core.exists
M.get = core.get
M.clear = core.clear
M.retry = core.retry
M.exists = core.exists
M.get = core.get
M.clear = core.clear

-- ─── Session State ─────────────────────────────────────────────
M.set_session_prompt = core.set_session_prompt
M.get_session_provider = core.get_session_provider
M.set_session_provider = core.set_session_provider
M.get_session_model = core.get_session_model
M.set_session_model = core.set_session_model
M.getcwd = core.getcwd
M.change_cwd = core.change_cwd
M.get_total_tokens = core.get_total_tokens

-- ─── Messages ──────────────────────────────────────────────────
M.append_message = messages.append_message
M.get_messages = messages.get_messages
M.get_request_messages = messages.get_request_messages

-- ─── Progress / Streaming ──────────────────────────────────────
M.on_progress = progress.on_progress
M.on_progress_done = progress.on_progress_done
M.on_progress_exit = progress.on_progress_exit
M.on_progress_reasoning_content = progress.on_progress_reasoning_content
M.get_progress_message = progress.get_progress_message
M.get_progress_reasoning_content = progress.get_progress_reasoning_content
M.get_progress_session = progress.get_progress_session
M.set_progress_usage = progress.set_progress_usage
M.set_progress_finish_reason = progress.set_progress_finish_reason
M.get_progress_finish_reason = progress.get_progress_finish_reason
M.get_progress_usage = progress.get_progress_usage
M.set_session_jobid = progress.set_session_jobid
M.is_in_progress = progress.is_in_progress
M.cancel_progress = progress.cancel_progress

-- ─── Tool Calls ────────────────────────────────────────────────
M.on_progress_tool_call = tools.on_progress_tool_call
M.on_progress_tool_call_done = tools.on_progress_tool_call_done

-- ─── Async Tools ───────────────────────────────────────────────
M.start_async_tool = async.start_async_tool
M.finish_async_tool = async.finish_async_tool
M.has_pending_async_tools = async.has_pending_async_tools
M.clear_cancelled = async.clear_cancelled

-- ─── Tool Results ──────────────────────────────────────────────
M.send_tool_results = tools.send_tool_results
M.on_complete = tools.on_complete

-- ─── Storage ───────────────────────────────────────────────────
M.write_cache = storage.write_cache
M.get_cache_path = storage.get_cache_path
M.iter_sessions = storage.iter_sessions

-- ─── Share / Import / Export ───────────────────────────────────
M.save_to_file = share.save_to_file
M.load_from_file = share.load_from_file
M.share = share.share
M.load_from_url = share.load_from_url

-- Initialize: load existing sessions
M.get()

return M


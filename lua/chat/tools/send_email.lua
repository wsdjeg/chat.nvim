-- lua/chat/tools/send_email.lua
-- Send an email via the system `mail` command.
-- Reference: https://wangchujiang.com/linux-command/c/mail.html
--   mail -s <subject> [-c <cc>] [-b <bcc>] <to>
--   body is piped to stdin (equivalent to: echo "body" | mail -s ...)
local M = {}

local job = require('job')

-- Cache mail availability check
local mail_available = nil
local function is_mail_available()
  if mail_available == nil then
    mail_available = vim.fn.executable('mail') == 1
  end
  return mail_available
end

-- Internal export for tests (same convention as providers' _convert_tools)
M._reset_availability_cache = function()
  mail_available = nil
end

--- Email address pattern: local@domain.tld
--- local: alnum . + - _   domain: alnum - . _ with at least one dot
local EMAIL_PATTERN = '^[%w%.%+%-_]+@[%w%-%.%_]+%.[%w%-%._]+$'

--- Validate a comma-separated list of email addresses.
--- Addresses starting with '-' are rejected to prevent option injection,
--- since they are appended after flags on the mail command line.
---@param addresses string Comma-separated addresses
---@param field string Field name for error messages
---@return string|nil error_message
local function validate_addresses(addresses, field)
  if type(addresses) ~= 'string' or #addresses == 0 then
    return string.format('%s is required and must be a non-empty string.', field)
  end
  for addr in addresses:gmatch('[^,]+') do
    addr = addr:gsub('^%s+', ''):gsub('%s+$', '')
    if #addr == 0 then
      return string.format('%s contains an empty address.', field)
    end
    if vim.startswith(addr, '-') then
      return string.format(
        '%s contains an option-like address "%s", which is not allowed.',
        field, addr
      )
    end
    if not addr:match(EMAIL_PATTERN) then
      return string.format('%s contains invalid address "%s".', field, addr)
    end
  end
  return nil
end

---@class ChatToolsSendEmailAction
---@field to string Recipient address(es), comma-separated
---@field subject string Email subject
---@field body? string Email body text (sent via stdin)
---@field cc? string Cc address(es), comma-separated
---@field bcc? string Bcc address(es), comma-separated

---@param action ChatToolsSendEmailAction
---@param ctx ChatToolContext
function M.send_email(action, ctx)
  -- Validate arguments first so validation errors surface even when
  -- the mail command is not installed (CI environments).
  local addr_err = validate_addresses(action.to, 'to')
  if addr_err then
    return { error = addr_err }
  end

  if type(action.subject) ~= 'string' or #action.subject == 0 then
    return { error = 'subject is required and must be a non-empty string.' }
  end

  if action.cc then
    addr_err = validate_addresses(action.cc, 'cc')
    if addr_err then
      return { error = addr_err }
    end
  end

  if action.bcc then
    addr_err = validate_addresses(action.bcc, 'bcc')
    if addr_err then
      return { error = addr_err }
    end
  end

  local body = action.body or ''
  if type(body) ~= 'string' then
    return { error = 'body must be a string.' }
  end

  -- Check mail availability after all validations
  if not is_mail_available() then
    return {
      error = 'mail is not installed or not in PATH.\n'
        .. 'Install one of: mailutils, bsd-mailx, s-nail '
        .. '(the mail command does not exist on Windows).',
    }
  end

  -- Build mail command (list form, never through a shell):
  -- mail -s <subject> [-c <cc>] [-b <bcc>] <to>
  local cmd = { 'mail', '-s', action.subject }
  if action.cc then
    table.insert(cmd, '-c')
    table.insert(cmd, action.cc)
  end
  if action.bcc then
    table.insert(cmd, '-b')
    table.insert(cmd, action.bcc)
  end
  table.insert(cmd, action.to)

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      vim.list_extend(stdout, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(id, code, signal)
      -- Guard against nil callback (e.g. test mock scenarios)
      if not ctx or not ctx.callback then
        return
      end

      if signal ~= 0 then
        ctx.callback({
          error = string.format(
            'send_email cancelled by user (signal: %d)',
            signal
          ),
          jobid = id,
        })
        return
      end

      local output = table.concat(stdout, '\n')
      if #stderr > 0 then
        if #output > 0 then
          output = output .. '\n'
        end
        output = output .. table.concat(stderr, '\n')
      end

      if code == 0 then
        local summary = 'Email sent successfully.\n'
          .. 'To: ' .. action.to .. '\n'
          .. 'Subject: ' .. action.subject .. '\n'
          .. 'Body: ' .. #body .. ' chars\n'
        if action.cc then
          summary = summary .. 'Cc: ' .. action.cc .. '\n'
        end
        if action.bcc then
          summary = summary .. 'Bcc: ' .. action.bcc .. '\n'
        end
        ctx.callback({ content = summary, exit_code = code, jobid = id })
      else
        local error_msg = string.format(
          'Failed to send email (exit %d):\n%s\n'
            .. 'Hint: make sure a mail transfer agent (sendmail/postfix) '
            .. 'is installed and configured.',
          code,
          #output > 0 and output or '(no output)'
        )
        ctx.callback({ error = error_msg, exit_code = code, jobid = id })
      end
    end,
  })

  if jobid > 0 then
    -- Pipe the body to stdin, then close it (EOF):
    -- equivalent to: echo "body" | mail -s "subject" to
    job.send(jobid, body)
    job.send(jobid, nil)
    return { jobid = jobid }
  end

  return { error = 'Failed to start mail process.' }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'send_email',
      description = [[
Send an email using the system `mail` command.

The body is piped to stdin, equivalent to:
  echo "body" | mail -s "subject" user@example.com

USAGE:
- @send_email to="user@example.com" subject="Hello" body="Hi there"
- @send_email to="a@x.com,b@x.com" subject="Report" body="See attachment list"
- @send_email to="user@example.com" subject="FYI" body="..." cc="boss@example.com"
- @send_email to="user@example.com" subject="FYI" body="..." bcc="audit@example.com"

PARAMETERS:
- to: recipient address(es), comma-separated (required)
- subject: email subject (required)
- body: email body text (optional, defaults to empty)
- cc: cc address(es), comma-separated (optional)
- bcc: bcc address(es), comma-separated (optional)

REQUIREMENTS:
- The `mail` command must be installed (mailutils / bsd-mailx / s-nail)
- A mail transfer agent (sendmail/postfix) must be configured for delivery
- Not available on Windows

SECURITY:
- Addresses are validated: option-like values are rejected
- Arguments are passed as a list, never through a shell
      ]],
      parameters = {
        type = 'object',
        properties = {
          to = {
            type = 'string',
            description = 'Recipient email address(es), comma-separated (required)',
          },
          subject = {
            type = 'string',
            description = 'Email subject (required)',
          },
          body = {
            type = 'string',
            description = 'Email body text, sent via stdin (optional)',
          },
          cc = {
            type = 'string',
            description = 'Cc address(es), comma-separated (optional)',
          },
          bcc = {
            type = 'string',
            description = 'Bcc address(es), comma-separated (optional)',
          },
        },
        required = { 'to', 'subject' },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, args = pcall(vim.json.decode, action)
  if ok then
    local parts = { 'send_email' }
    if args.to then
      table.insert(parts, string.format('to="%s"', args.to))
    end
    if args.subject then
      table.insert(parts, string.format('subject="%s"', args.subject))
    end
    if args.cc then
      table.insert(parts, string.format('cc="%s"', args.cc))
    end
    if args.bcc then
      table.insert(parts, string.format('bcc="%s"', args.bcc))
    end
    return table.concat(parts, ' ')
  end
  return 'send_email'
end

return M


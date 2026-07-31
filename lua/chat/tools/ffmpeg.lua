local M = {}

local util = require('chat.util')
local job = require('job')

-- Cache ffmpeg availability check
local ffmpeg_available = nil
local function is_ffmpeg_available()
  if ffmpeg_available == nil then
    ffmpeg_available = vim.fn.executable('ffmpeg') == 1
  end
  return ffmpeg_available
end

--- Supported input image formats
local SUPPORTED_EXTENSIONS = {
  png = true,
  jpg = true,
  jpeg = true,
  bmp = true,
  gif = true,
  tiff = true,
  tga = true,
  webp = true,
}

---@class ChatToolsFfmpegAction
---@field input string Source image file path
---@field output? string Output webp file path (default: same name with .webp)
---@field quality? integer WebP quality 0-100 (default: 80)

--- Format file size to human readable
---@param size number
---@return string
local function format_size(size)
  if size < 0 then
    return '-'
  end
  if size < 1024 then
    return string.format('%dB', size)
  elseif size < 1024 * 1024 then
    return string.format('%.1fKB', size / 1024)
  elseif size < 1024 * 1024 * 1024 then
    return string.format('%.1fMB', size / (1024 * 1024))
  else
    return string.format('%.1fGB', size / (1024 * 1024 * 1024))
  end
end

--- Get file extension (lowercase, without dot)
---@param filepath string
---@return string
local function get_extension(filepath)
  local ext = filepath:match('%.([^.]+)$')
  return ext and ext:lower() or ''
end

--- Resolve and validate a path within cwd and allowed_path
---@param path string
---@param cwd string
---@param label string for error messages
---@return string? resolved_path
---@return string? error
local function resolve_and_validate(path, cwd, label)
  if
    not path
    or type(path) ~= 'string'
    or path == ''
  then
    return nil, label .. ' is required and must be a non-empty string.'
  end

  local resolved = util.resolve(path, cwd)
  if not resolved then
    return nil, 'Failed to resolve ' .. label .. '.'
  end

  local norm_cwd = vim.fs.normalize(cwd)
  if not norm_cwd:match('[/\\]$') then
    norm_cwd = norm_cwd .. '/'
  end

  if not vim.startswith(resolved, norm_cwd) then
    return nil, string.format(
      'Security: %s must be within working directory.\n  path: %s\n  cwd: %s',
      label, resolved, norm_cwd
    )
  end

  if not util.is_allowed_path(resolved) then
    return nil, string.format(
      'Security: %s is not in allowed_path.\n  path: %s',
      label, resolved
    )
  end

  return resolved, nil
end

---@param action ChatToolsFfmpegAction
---@param ctx ChatToolContext
function M.ffmpeg(action, ctx)
  if not ctx.cwd or ctx.cwd == '' then
    return { error = 'No working directory (cwd) specified in context.' }
  end

  -- Validate input
  local input_path, input_err =
    resolve_and_validate(action.input, ctx.cwd, 'input')
  if input_err then
    return { error = input_err }
  end

  -- Check input exists and is a file
  if vim.fn.getftype(input_path) ~= 'file' then
    return { error = string.format('Input file does not exist: %s', input_path) }
  end

  -- Validate input format
  local input_ext = get_extension(input_path)
  if not SUPPORTED_EXTENSIONS[input_ext] then
    return {
      error = string.format(
        'Unsupported input format: .%s\nSupported: %s',
        input_ext, table.concat(vim.tbl_keys(SUPPORTED_EXTENSIONS), ', ')
      ),
    }
  end

  -- Determine output path
  local output_path
  if action.output and type(action.output) == 'string' and #action.output > 0 then
    local out, out_err =
      resolve_and_validate(action.output, ctx.cwd, 'output')
    if out_err then
      return { error = out_err }
    end
    -- Ensure output has .webp extension
    if get_extension(out) ~= 'webp' then
      out = out .. '.webp'
    end
    output_path = out
  else
    -- Default: same name with .webp extension
    local base = input_path:gsub('%.[^.]+$', '')
    output_path = base .. '.webp'
  end

  -- Validate quality (0-100, default 80)
  local quality = 80
  if action.quality ~= nil then
    if
      type(action.quality) ~= 'number'
      or action.quality < 0
      or action.quality > 100
    then
      return {
        error = 'quality must be a number between 0 and 100 (got: '
          .. tostring(action.quality) .. ')',
      }
    end
    quality = math.floor(action.quality)
  end

  -- Check ffmpeg availability after all validations
  if not is_ffmpeg_available() then
    return {
      error = 'ffmpeg is not installed or not in PATH.\n'
        .. 'Install ffmpeg: https://ffmpeg.org/download.html',
    }
  end

  -- Get original file size for comparison
  local original_size = vim.fn.getfsize(input_path)

  -- Build ffmpeg command:
  -- ffmpeg -y -i <input> -c:v libwebp -quality 80 <output>
  -- -y: overwrite output without asking
  local cmd = {
    'ffmpeg', '-y',
    '-i', input_path,
    '-c:v', 'libwebp',
    '-quality', tostring(quality),
    output_path,
  }

  local stderr = {}

  local jobid = job.start(cmd, {
    cwd = ctx.cwd,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(id, code, signal)
      if signal ~= 0 then
        ctx.callback({
          error = string.format('ffmpeg cancelled (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      if code ~= 0 then
        local error_output = table.concat(stderr, '\n')
        ctx.callback({
          error = string.format(
            'ffmpeg failed (exit code: %d)\n%s',
            code,
            error_output ~= '' and error_output or 'No error output.'
          ),
          exit_code = code,
          jobid = id,
        })
        return
      end

      -- Success: get output file size
      local output_size = vim.fn.getfsize(output_path)
      local ratio = 'N/A'
      if original_size > 0 and output_size > 0 then
        local r = output_size / original_size * 100
        if r < 100 then
          ratio = string.format('%.1f%% (saved %.1f%%)', r, 100 - r)
        else
          ratio = string.format('%.1f%% (larger by %.1f%%)', r, r - 100)
        end
      end

      local summary = string.format(
        '✓ Converted to WebP\n  input:  %s (%s)\n  output: %s (%s)\n  size:   %s\n  quality: %d',
        input_path, format_size(original_size),
        output_path, format_size(output_size),
        ratio,
        quality
      )

      ctx.callback({
        content = summary,
        exit_code = code,
        jobid = id,
      })
    end,
  })

  if jobid > 0 then
    return { jobid = jobid }
  end

  return { error = 'Failed to start ffmpeg process.' }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'ffmpeg',
      description = [[Convert images to WebP format using ffmpeg.

Compresses PNG, JPG, JPEG, BMP, GIF, TIFF, TGA images to WebP for smaller file sizes.

USAGE:
- @ffmpeg input="photo.png"                        # Convert to photo.webp (quality: 80)
- @ffmpeg input="photo.png" quality=60             # Lower quality for smaller size
- @ffmpeg input="photo.png" output="compressed.webp"  # Custom output name
- @ffmpeg input="images/big.jpg" quality=90        # High quality

PARAMETERS:
- input: Source image file path (required)
- output: Output webp path (default: same name with .webp extension)
- quality: WebP quality 0-100, higher = better quality (default: 80)

REQUIREMENTS:
- ffmpeg must be installed with libwebp encoder
- Install: https://ffmpeg.org/download.html
      ]],
      parameters = {
        type = 'object',
        properties = {
          input = {
            type = 'string',
            description = 'Source image file path (relative to cwd or absolute)',
          },
          output = {
            type = 'string',
            description = 'Output webp file path (default: same name with .webp extension)',
          },
          quality = {
            type = 'integer',
            description = 'WebP quality 0-100, higher = better quality but larger (default: 80)',
          },
        },
        required = { 'input' },
      },
    },
  }
end

function M.info(action_str, ctx)
  local ok, args = pcall(vim.json.decode, action_str)
  if ok then
    local input = util.resolve(args.input, ctx.cwd) or args.input
    local parts = { string.format('ffmpeg %s', input) }
    if args.quality then
      table.insert(parts, string.format('quality=%s', args.quality))
    end
    if args.output then
      local output = util.resolve(args.output, ctx.cwd) or args.output
      table.insert(parts, string.format('output=%s', output))
    end
    return table.concat(parts, ' ')
  end
  return 'ffmpeg'
end

return M


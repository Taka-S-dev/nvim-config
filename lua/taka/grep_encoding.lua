-- The searches of snacks and :grep for a tree where some files are Shift-JIS
-- (lua/taka/lib/legacy_text.lua). rg reads every file as UTF-8 unless told one
-- encoding for all of them: Japanese typed was not found in a file in cp932,
-- and a line of one found by its ASCII came out garbled in the list and the
-- preview. Each search now asks for both, and what comes back is shown as the
-- file shows when opened, without anything to choose.
local legacy = require("taka.lib.legacy_text")

local M = {}

-- The bytes of a match in the bytes of the line, as bytes of the text shown.
local function shown_positions(raw, positions)
  local out, index = {}, 1
  while positions and index <= #positions do
    local first, last = positions[index], positions[index]
    while positions[index + 1] == last + 1 do
      index = index + 1
      last = positions[index]
    end
    for at = legacy.column(raw, first - 1) + 1, legacy.column(raw, last) do
      out[#out + 1] = at
    end
    index = index + 1
  end
  return #out > 0 and out or nil
end

-- A result of rg made to read as the file does. Its line and where the match
-- is in it are worked out by snacks only when the row is drawn, so they are
-- converted then; the text the list filters on goes with the rest of the
-- result.
local function convert(item)
  local head = ("%s:%d:%d:"):format(item.file, item.pos[1], item.pos[2] + 1)
  if item.text:sub(1, #head) == head then
    item.text = head .. legacy.text(item.text:sub(#head + 1))
  end
  local resolve = item.resolve
  item.resolve = function(self)
    resolve(self)
    local raw = item.line
    if not raw then
      return
    end
    local line, converted = legacy.text(raw)
    if not converted then
      return
    end
    item.line = line
    item.positions = shown_positions(raw, item.positions)
    item.pos[2] = legacy.column(raw, item.pos[2])
    if item.end_pos then
      item.end_pos[2] = legacy.column(raw, item.end_pos[2])
    end
  end
end

-- What rg's smart case would say of the search as typed. A byte written in
-- the search for cp932 can be a capital letter, and rg would take it for one
-- typed.
local function has_capital(typed)
  return typed:gsub("\\.", ""):find("%u") ~= nil
end

-- snacks' grep, the search typed made to find both encodings. It reads the
-- search off the filter when it builds the command, at once, so the filter
-- is changed only for that call. The options typed after ` -- ` stay as they
-- are.
function M.finder(opts, ctx)
  local grep = require("snacks.picker.source.grep").grep
  local filter, search = ctx.filter, ctx.filter.search
  local head, options = search:match("^(.-)(%s+%-%-%s*.*)$")
  local typed = head and vim.trim(head) or search
  local pattern, changed = legacy.pattern(typed, opts.regex == false)
  local run_opts = opts
  if changed then
    local args = vim.deepcopy(opts.args or {})
    if not has_capital(typed) and not vim.tbl_contains(args, "--case-sensitive") then
      args[#args + 1] = "--ignore-case"
    end
    run_opts = setmetatable({ regex = true, args = args }, { __index = opts })
    filter.search = pattern .. (options or "")
  end
  local ok, run = pcall(grep, run_opts, ctx)
  filter.search = search
  if not ok then
    error(run, 0)
  end
  return function(callback, ...)
    return run(function(item)
      convert(item)
      return callback(item)
    end, ...)
  end
end

-- The preview of a file not open: snacks puts its bytes in as they are.
local function wrap_preview()
  local preview = require("snacks.picker.preview")
  if preview.taka_legacy_text then
    return
  end
  local file = preview.file
  preview.file = function(ctx)
    local result = file(ctx)
    local loaded = ctx.item.buf and vim.api.nvim_buf_is_loaded(ctx.item.buf)
    if not loaded and vim.api.nvim_buf_is_valid(ctx.buf) then
      local lines, converted = legacy.lines(vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false))
      if converted then
        ctx.preview:set_lines(lines)
        ctx.preview:loc()
      end
    end
    return result
  end
  preview.taka_legacy_text = true
end

-- The results of :grep and :lgrep read as the files do. What is searched for
-- cannot be changed here: the command goes to the shell as typed.
local function convert_list(args)
  local local_list = args.match:sub(1, 1) == "l"
  local items = local_list and vim.fn.getloclist(0) or vim.fn.getqflist()
  local any = false
  for _, item in ipairs(items) do
    local text, converted = legacy.text(item.text)
    if converted then
      item.col = legacy.column(item.text, item.col - 1) + 1
      item.text, any = text, true
    end
  end
  if not any then
    return
  end
  if local_list then
    vim.fn.setloclist(0, {}, "r", { items = items })
  else
    vim.fn.setqflist({}, "r", { items = items })
  end
end

function M.setup()
  wrap_preview()
  vim.api.nvim_create_autocmd("QuickFixCmdPost", {
    group = vim.api.nvim_create_augroup("config_grep_encoding", { clear = true }),
    pattern = { "grep", "grepadd", "lgrep", "lgrepadd" },
    callback = convert_list,
  })
end

return M

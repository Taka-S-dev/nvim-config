-- Where the marks of a file are, at a glance: a strip two cells wide down the
-- right edge of each window of a file, the whole file squeezed into the
-- window's height, as the strip of a diff is drawn (lua/taka/diff/map.lua).
-- <leader>uM shows the strips and puts them away.
--
--   left cell   the part of the file the window shows, in the colour of a
--               selection; the cursor's line, bright; the changes git or
--               svn sees, in their colours
--   right cell  the strongest mark on those lines, in its own colour:
--               a line marked (<leader>hl, both cells), a word lit
--               (<leader>hh), a mark (ma), what the search finds, a pin, a
--               step of the trace, a debug line, an error, a warning
--
-- A click on the strip goes there. A map of the code drawn small, in dots,
-- read the same all the way down a file of C, and showed none of these.
local M = {}

local ns = vim.api.nvim_create_namespace("config_overview")
local WIDTH = 2
-- A column left clear at the edge, as the diff's strip has, so that a click
-- meant for the border between two windows does not jump.
local GAP = 1

M.enabled = true

local strips = {} ---@type table<integer, { float: integer, buf: integer }>

-- What a mark is drawn as, the strongest first: the colour group whose colour
-- the cell takes, and which of its colours.
local KINDS = {
  { name = "line", group = "LineMarkNr", attr = "fg" },
  { name = "word" }, -- in the colour of its word
  { name = "mark", group = "SnacksStatusColumnMark", attr = "fg" },
  { name = "search", group = "Search", attr = "bg" },
  { name = "pin", group = "PinSign", attr = "fg" },
  { name = "trace", group = "TraceStep", attr = "fg" },
  { name = "debug", group = "DebugLineMark", attr = "fg" },
  { name = "error", group = "DiagnosticError", attr = "fg" },
  { name = "warn", group = "DiagnosticWarn", attr = "fg" },
}
local RANK = {}
for index, kind in ipairs(KINDS) do
  RANK[kind.name] = #KINDS - index + 1
end
local GIT = { add = "GitSignsAdd", change = "GitSignsChange", delete = "GitSignsDelete" }

local function colour(name, attr)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl[attr] or hl.fg or hl.bg
end

-- The strip's groups take their colours from others', read again at each
-- drawing and set only when they differ from what was set: read once, at
-- start, a passing colour stayed, and the whole track came out in the colour
-- of the part in view.
local set = {}
local function put(group, spec)
  local key = vim.inspect(spec)
  if set[group] ~= key then
    vim.api.nvim_set_hl(0, group, spec)
    set[group] = key
  end
end

-- The group a cell is drawn in: `OverviewX` with the colour of another as its
-- background.
local function cell(name, source, attr)
  local group = "Overview" .. name
  put(group, { bg = colour(source, attr) })
  return group
end

local function colours()
  put("OverviewTrack", { link = "CursorLine" })
  -- The part in view in the colour of a selection: halfway to the grey of a
  -- comment, it was hardly told from the track.
  put("OverviewView", { link = "Visual" })
  put("OverviewCursor", { bg = colour("CursorLineNr", "fg") })
end

-- The lines `pattern` (a Vim pattern) is found on in `buf`, as a set.
local function found(buf, pattern, out, kind, extra)
  local ok, hits = pcall(vim.fn.matchbufline, buf, pattern, 1, "$")
  for _, hit in ipairs(ok and hits or {}) do
    out[#out + 1] = { line = hit.lnum, kind = kind, extra = extra }
  end
end

-- The lines of `buf` an extmark of the namespace `name` is on.
local function marked(buf, name, out, kind, keep)
  local id = vim.api.nvim_get_namespaces()[name]
  if not id then
    return
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
    if not keep or keep(mark[4]) then
      out[#out + 1] = { line = mark[2] + 1, kind = kind }
    end
  end
end

-- The marks of `buf`: { line, kind, extra } for the right cell, and the
-- changes { line, kind } for the left.
local function collect(buf)
  local marks, changes = {}, {}
  marked(buf, "config_line_marks", marks, "line")
  local ok, words = pcall(function()
    return require("taka.words").lit()
  end)
  for _, word in ipairs(ok and words or {}) do
    found(buf, word.pattern, marks, "word", word.colour)
  end
  local search = vim.fn.getreg("/")
  if vim.v.hlsearch == 1 and search ~= "" then
    found(buf, search, marks, "search")
  end
  -- The marks set with m: a to z of this file, and A to Z where they are in
  -- it, as the column of signs shows them.
  for code = ("a"):byte(), ("z"):byte() do
    local line = vim.api.nvim_buf_get_mark(buf, string.char(code))[1]
    if line > 0 then
      marks[#marks + 1] = { line = line, kind = "mark" }
    end
  end
  for code = ("A"):byte(), ("Z"):byte() do
    local mark = vim.api.nvim_get_mark(string.char(code), {})
    if mark[1] > 0 and mark[3] == buf then
      marks[#marks + 1] = { line = mark[1], kind = "mark" }
    end
  end
  marked(buf, "config_pins", marks, "pin")
  marked(buf, "config_trace", marks, "trace", function(details)
    return details.sign_text ~= nil
  end)
  marked(buf, "taka.debug_lines", marks, "debug")
  for _, diagnostic in ipairs(vim.diagnostic.get(buf, { severity = { min = vim.diagnostic.severity.WARN } })) do
    marks[#marks + 1] = {
      line = diagnostic.lnum + 1,
      kind = diagnostic.severity == vim.diagnostic.severity.ERROR and "error" or "warn",
    }
  end
  local okg, hunks = pcall(function()
    return require("gitsigns").get_hunks(buf)
  end)
  for _, hunk in ipairs(okg and hunks or {}) do
    local first = math.max(hunk.added.start, 1)
    for line = first, first + math.max(hunk.added.count, 1) - 1 do
      changes[#changes + 1] = { line = line, kind = hunk.type }
    end
  end
  -- svn's changes, drawn by vim-signify as signs.
  for _, placed in ipairs(vim.fn.sign_getplaced(buf, { group = "*" })) do
    for _, sign in ipairs(placed.signs) do
      local kind = sign.name:match("^SignifyAdd") and "add"
        or sign.name:match("^SignifyRemove") and "delete"
        or sign.name:match("^SignifyDelete") and "delete"
        or sign.name:match("^SignifyChange") and "change"
      if kind then
        changes[#changes + 1] = { line = sign.lnum, kind = kind }
      end
    end
  end
  return marks, changes
end

local function close(win)
  local strip = strips[win]
  strips[win] = nil
  if strip and vim.api.nvim_win_is_valid(strip.float) then
    vim.api.nvim_win_close(strip.float, true)
  end
end

-- Whether a window gets a strip: a window of a file, not a diff, which has
-- its own, and room enough.
local function wanted(win)
  if not M.enabled or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].diff then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
    and vim.api.nvim_win_get_height(win) >= 3
    and vim.api.nvim_win_get_width(win) >= 30
end

local function draw(win)
  if not wanted(win) then
    return close(win)
  end
  colours()
  local height, width = vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
  local place = { relative = "win", win = win, row = 0, col = width - WIDTH - GAP, width = WIDTH, height = height }
  local strip = strips[win]
  if not strip or not vim.api.nvim_win_is_valid(strip.float) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local float = vim.api.nvim_open_win(
      buf,
      false,
      vim.tbl_extend("force", place, { focusable = false, style = "minimal", zindex = 20, noautocmd = true })
    )
    strip = { float = float, buf = buf }
    strips[win] = strip
  else
    vim.api.nvim_win_set_config(strip.float, place)
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local total = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local marks, changes = collect(buf)
  -- The strongest mark and the change of each row of the strip.
  local right, left = {}, {}
  local function row_of(line)
    return math.min(height - 1, math.floor((line - 1) * height / total))
  end
  for _, mark in ipairs(marks) do
    local row = row_of(mark.line)
    local was = right[row]
    if not was or RANK[mark.kind] > RANK[was.kind] then
      right[row] = mark
    end
  end
  for _, change in ipairs(changes) do
    left[row_of(change.line)] = change.kind
  end
  local top, bottom = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local cursor = row_of(vim.api.nvim_win_get_cursor(win)[1])
  strip.cursor = cursor
  local lines = {}
  for _ = 1, height do
    lines[#lines + 1] = (" "):rep(WIDTH)
  end
  vim.api.nvim_buf_set_lines(strip.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(strip.buf, ns, 0, -1)
  for row = 0, height - 1 do
    local first = math.floor(row * total / height) + 1
    local last = math.max(first, math.floor((row + 1) * total / height))
    local track = (first <= bottom and last >= top) and "OverviewView" or "OverviewTrack"
    local change = left[row]
    local mark = right[row]
    -- A line marked takes both cells: in the yellow of the first word lit too,
    -- it was told from a word only by being as wide.
    local left_group = change and cell("Git" .. change, GIT[change] or "GitSignsChange", "fg") or track
    if mark and mark.kind == "line" then
      left_group = cell("line", "LineMarkNr", "fg")
    end
    -- Where the cursor is, over all else in the left cell, so a mark's place
    -- is told against it: above, below, or this row.
    if row == cursor then
      left_group = "OverviewCursor"
    end
    vim.api.nvim_buf_set_extmark(strip.buf, ns, row, 0, { end_col = 1, hl_group = left_group })
    local group = track
    if mark and mark.kind == "word" then
      group = cell("Word" .. mark.extra, "Word" .. mark.extra, "bg")
    elseif mark then
      for _, kind in ipairs(KINDS) do
        if kind.name == mark.kind then
          group = cell(kind.name, kind.group, kind.attr)
        end
      end
    end
    vim.api.nvim_buf_set_extmark(strip.buf, ns, row, 1, { end_col = WIDTH, hl_group = group })
  end
end

-- Every window of the current tab.
function M.refresh()
  for win in pairs(strips) do
    if not vim.api.nvim_win_is_valid(win) then
      close(win)
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and (wanted(win) or strips[win]) then
      draw(win)
    end
  end
end

-- Drawn once the editor is idle after a run of changes: the marks of a large
-- file are searched for anew at each drawing.
local timer
local function soon()
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(80, 0, vim.schedule_wrap(M.refresh))
end
M.soon = soon

-- <leader>uM: the strips shown or put away.
function M.toggle()
  M.enabled = not M.enabled
  M.refresh()
  vim.notify(M.enabled and "Overview strips shown" or "Overview strips put away")
end

-- The line a row of a window's strip stands for: the first mark in it, when
-- it shows one, rather than the top of the part of the file it covers.
local function line_at(win, row)
  local buf = vim.api.nvim_win_get_buf(win)
  local height, total = vim.api.nvim_win_get_height(win), math.max(vim.api.nvim_buf_line_count(buf), 1)
  local first = math.floor(row * total / height) + 1
  local last = math.max(first, math.floor((row + 1) * total / height))
  local marks, changes = collect(buf)
  local best
  for _, mark in ipairs(vim.list_extend(marks, changes)) do
    if mark.line >= first and mark.line <= last and (not best or mark.line < best) then
      best = mark.line
    end
  end
  return best or first
end

-- Where a click lands, when it lands on a strip: the window and the line.
function M.target()
  local mouse = vim.fn.getmousepos()
  local win = mouse.winid
  if not strips[win] then
    return nil
  end
  local last = vim.api.nvim_win_get_width(win) - GAP
  if mouse.wincol > last - WIDTH and mouse.wincol <= last then
    local bar = (vim.fn.getwininfo(win)[1] or {}).winbar or 0
    local row = mouse.winrow - 1 - bar
    if row >= 0 then
      return win, line_at(win, row)
    end
  end
end

local group = vim.api.nvim_create_augroup("config_overview", { clear = true })
-- :highlight clear has emptied the groups: set them all again.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    set = {}
    colours()
  end,
})
vim.api.nvim_create_autocmd({
  "BufWinEnter",
  "WinEnter",
  "TabEnter",
  "WinScrolled",
  "WinResized",
  "TextChanged",
  "InsertLeave",
  "DiagnosticChanged",
  "CursorHold",
  "CmdlineLeave",
  "OptionSet",
}, { group = group, callback = soon })
vim.api.nvim_create_autocmd("User", { group = group, pattern = { "GitSignsUpdate" }, callback = soon })
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(event)
    close(tonumber(event.match))
  end,
})
-- n, N, * and # search without an event of their own, and m sets a mark
-- without one; the strip follows on the next move of the cursor. It is drawn
-- again then only when something it shows has changed: the search, or the
-- row of the strip the cursor is on.
vim.api.nvim_create_autocmd("CursorMoved", {
  group = group,
  callback = function()
    local key = vim.v.hlsearch .. vim.fn.getreg("/")
    local win = vim.api.nvim_get_current_win()
    local strip = strips[win]
    local moved = false
    if strip then
      local height = vim.api.nvim_win_get_height(win)
      local total = math.max(vim.api.nvim_buf_line_count(0), 1)
      local row = math.min(height - 1, math.floor((vim.fn.line(".") - 1) * height / total))
      moved = row ~= strip.cursor
    end
    if key ~= M.last_search or moved then
      M.last_search = key
      soon()
    end
  end,
})
colours()

-- For the checks: the strip of a window, row by row, the two cells' groups.
function M.strip(win)
  M.refresh()
  local strip = strips[win]
  if not strip then
    return nil
  end
  local out = {}
  for row = 0, vim.api.nvim_win_get_height(win) - 1 do
    local cells = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(strip.buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
      cells[#cells + 1] = mark[4].hl_group
    end
    out[#out + 1] = cells
  end
  return out
end

return M

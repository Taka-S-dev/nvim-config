-- Where a diff differs, at a glance, as WinMerge's location pane shows it: a
-- strip two cells wide down the right edge of every window in diff mode, one
-- column in from the edge, the whole file squeezed into the window's height.
--
--   right cell  green where lines are only on this side, amber where a line
--               changed, red where lines are only on the other side
--   the part of the file the window shows is a lighter band across the strip,
--   with a bright edge in the left cell, as WinMerge frames it
--
-- A click on the strip goes there. Rows are counted with the filler lines the
-- diff puts in for the other side, so the strips of the two sides line up.
-- Nothing here depends on where the diff came from: svn, git or :diffthis.
local M = {}

local maps = {} ---@type table<integer, { float: integer, buf: integer, rows: string[]?, tick: integer? }>
local ns = vim.api.nvim_create_namespace("config_diff_map")
local WIDTH = 2
-- A column left clear between the strip and the window's edge, so that a click
-- meant for the border between two windows, to drag it, does not land on the
-- strip and jump.
local GAP = 1

local function colours()
  local function colour(name, attr)
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    return hl[attr]
  end
  -- Halfway between two colours, for the band: lighter than the track, and
  -- still darker than the edge and every change drawn over it.
  local function between(a, b)
    if not a or not b then
      return a or b
    end
    local mixed = 0
    for shift = 0, 16, 8 do
      local x, y = bit.band(bit.rshift(a, shift), 255), bit.band(bit.rshift(b, shift), 255)
      mixed = mixed + bit.lshift(math.floor((x + y) / 2), shift)
    end
    return mixed
  end
  local track, edge = colour("CursorLine", "bg"), colour("Comment", "fg")
  vim.api.nvim_set_hl(0, "DiffMapTrack", { bg = track, default = true })
  vim.api.nvim_set_hl(0, "DiffMapView", { bg = edge, default = true })
  vim.api.nvim_set_hl(0, "DiffMapViewFill", { bg = between(track, edge), default = true })
  vim.api.nvim_set_hl(0, "DiffMapAdd", { bg = colour("GitSignsAdd", "fg") or colour("Added", "fg"), default = true })
  vim.api.nvim_set_hl(0, "DiffMapChange", { bg = colour("DiagnosticWarn", "fg"), default = true })
  vim.api.nvim_set_hl(
    0,
    "DiffMapDelete",
    { bg = colour("GitSignsDelete", "fg") or colour("Removed", "fg"), default = true }
  )
end

local STATE = { DiffAdd = "add", DiffChange = "change", DiffText = "change" }
local PRIORITY = { change = 3, add = 2, fill = 1 }
local HL = { add = "DiffMapAdd", change = "DiffMapChange", fill = "DiffMapDelete" }

-- One entry per row of the aligned diff: each filler line the other side put
-- above a line, then the line itself. `first[l]` is the row of line l.
local function scan(win)
  return vim.api.nvim_win_call(win, function()
    local rows, first = {}, {}
    local count = vim.api.nvim_buf_line_count(0)
    for line = 1, count + 1 do
      for _ = 1, vim.fn.diff_filler(line) do
        rows[#rows + 1] = "fill"
      end
      if line <= count then
        first[line] = #rows + 1
        local id = vim.fn.diff_hlID(line, 1)
        rows[#rows + 1] = id ~= 0 and STATE[vim.fn.synIDattr(id, "name")] or false
      end
    end
    -- One value: nvim_win_call passes back no more.
    return { rows = rows, first = first }
  end)
end

local function close(win)
  local map = maps[win]
  maps[win] = nil
  if map and vim.api.nvim_win_is_valid(map.float) then
    vim.api.nvim_win_close(map.float, true)
  end
end

local function draw(win, rescan)
  if not vim.api.nvim_win_is_valid(win) or not vim.wo[win].diff then
    return close(win)
  end
  local height, width = vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
  if height < 3 or width < 20 then
    return close(win)
  end
  local map = maps[win]
  if not map or not vim.api.nvim_win_is_valid(map.float) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local float = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = win,
      row = 0,
      col = width - WIDTH - GAP,
      width = WIDTH,
      height = height,
      focusable = false,
      style = "minimal",
      zindex = 20,
      noautocmd = true,
    })
    map = { float = float, buf = buf }
    maps[win] = map
  else
    vim.api.nvim_win_set_config(map.float, {
      relative = "win",
      win = win,
      row = 0,
      col = width - WIDTH - GAP,
      width = WIDTH,
      height = height,
    })
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local tick = vim.b[buf].changedtick
  if rescan or not map.rows or map.tick ~= tick then
    local scanned = scan(win)
    map.rows, map.first = scanned.rows, scanned.first
    map.tick = tick
  end
  local rows, total = map.rows, math.max(#map.rows, 1)
  local top = map.first[vim.fn.line("w0", win)] or 1
  local bottom = map.first[vim.fn.line("w$", win)] or total
  local lines = {}
  for _ = 1, height do
    lines[#lines + 1] = (" "):rep(WIDTH)
  end
  vim.api.nvim_buf_set_lines(map.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(map.buf, ns, 0, -1)
  for row = 0, height - 1 do
    local from = math.floor(row * total / height) + 1
    local to = math.max(from, math.floor((row + 1) * total / height))
    local state
    for index = from, math.min(to, #rows) do
      local here = rows[index]
      if here and (not state or PRIORITY[here] > PRIORITY[state]) then
        state = here
      end
    end
    local seen = from <= bottom and to >= top
    vim.api.nvim_buf_set_extmark(map.buf, ns, row, 0, {
      end_col = 1,
      hl_group = seen and "DiffMapView" or "DiffMapTrack",
    })
    vim.api.nvim_buf_set_extmark(map.buf, ns, row, 1, {
      end_col = WIDTH,
      hl_group = state and HL[state] or seen and "DiffMapViewFill" or "DiffMapTrack",
    })
  end
end

-- Every window of the current tab: a diff can start or end in any of them.
local function refresh(rescan)
  for win in pairs(maps) do
    if not vim.api.nvim_win_is_valid(win) then
      close(win)
    end
  end
  -- The strips are windows too, and drawing one window can close another's.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ""
      and (vim.wo[win].diff or maps[win])
    then
      draw(win, rescan)
    end
  end
end

-- The line a row of the strip stands for: the first change within it, when
-- it shows one, rather than the top of the part of the file it covers.
local function line_at(win, row)
  local map = maps[win]
  local height, total = vim.api.nvim_win_get_height(win), math.max(#map.rows, 1)
  local from = math.floor(row * total / height) + 1
  local to = math.max(from, math.floor((row + 1) * total / height))
  local wanted = from
  for index = from, math.min(to, #map.rows) do
    if map.rows[index] then
      wanted = index
      break
    end
  end
  local line = 1
  for index, first in ipairs(map.first) do
    if first > wanted then
      break
    end
    line = index
  end
  return line
end

-- Where a click lands, when it lands on a strip: the diff window and the line.
-- The strip takes no focus, so the click is reported against the diff window,
-- in the two columns before the clear one at its edge.
function M.target()
  local mouse = vim.fn.getmousepos()
  local win = mouse.winid
  local last = vim.api.nvim_win_get_width(win) - GAP
  if maps[win] and mouse.wincol > last - WIDTH and mouse.wincol <= last then
    return win, line_at(win, mouse.winrow - 1)
  end
end

-- A click on a strip goes to that part of the file; any other click is left
-- to do what it does. The mapping only decides: an expression mapping may not
-- change windows (E565), so the move comes after it.
vim.keymap.set("n", "<LeftMouse>", function()
  local win, line = M.target()
  if not win then
    return "<LeftMouse>"
  end
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      vim.cmd("normal! zz")
    end
  end)
  return ""
end, { expr = true, desc = "Click, or go to where the diff map points" })

local group = vim.api.nvim_create_augroup("config_diff_map", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = colours })
vim.api.nvim_create_autocmd({ "DiffUpdated", "BufWinEnter", "WinEnter", "TabEnter" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      refresh(true)
    end)
  end,
})
vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
  group = group,
  callback = function()
    refresh(false)
  end,
})
vim.api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = "diff",
  callback = function()
    vim.schedule(function()
      refresh(true)
    end)
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(event)
    close(tonumber(event.match))
  end,
})
colours()

-- For the checks: the strip of a window, row by row, as "<view><state>".
function M.strip(win)
  refresh(false)
  local map = maps[win]
  if not map then
    return nil
  end
  local out = {}
  for row = 0, vim.api.nvim_win_get_height(win) - 1 do
    local marks = vim.api.nvim_buf_get_extmarks(map.buf, ns, { row, 0 }, { row, -1 }, { details = true })
    local cells = {}
    for _, mark in ipairs(marks) do
      local name = mark[4].hl_group
      cells[#cells + 1] = ({
        DiffMapTrack = ".",
        DiffMapView = "v",
        DiffMapViewFill = ",",
        DiffMapAdd = "+",
        DiffMapChange = "~",
        DiffMapDelete = "-",
      })[name] or "?"
    end
    out[#out + 1] = table.concat(cells)
  end
  return out
end

return M

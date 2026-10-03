-- The two sides of a diff scroll together, however one of them is scrolled.
--
-- Diff mode binds their scrolling, but the binding only acts after a command
-- run in the current window. A view moved any other way leaves the other side
-- where it was: the mouse wheel over the side the cursor is not in, as when
-- the cursor is still in the svn log's list, or the smooth scrolling that
-- moves the view a step at a time. Whenever a window of a diff scrolls, the
-- other sides are brought to the same row of the diff, and their cursors to
-- the row the scrolled side's cursor is on.
--
-- The rows are counted here rather than left to :syncbind, which at the edge
-- of a fold lands tens of lines away from the match.
local M = {}

local syncing = false

-- For each window of a diff, the row of the aligned diff each line ends on:
-- every line above it and itself, and every filler line put in for the other
-- side above them. Counted once per diff and kept while the text stays as it
-- was, since counting a long file on every step of the wheel is felt.
local ends = {} ---@type table<integer, { tick: integer, buf: integer, rows: integer[] }>

local function rows_of(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local tick = vim.b[buf].changedtick
  local kept = ends[win]
  if kept and kept.tick == tick and kept.buf == buf then
    return kept.rows
  end
  local rows, at = {}, 0
  vim.api.nvim_win_call(win, function()
    for line = 1, vim.api.nvim_buf_line_count(buf) do
      at = at + vim.fn.diff_filler(line) + 1
      rows[line] = at
    end
  end)
  ends[win] = { tick = tick, buf = buf, rows = rows }
  return rows
end

-- The line on a row, and how many of the filler lines above it come before
-- the row; a row that is a filler line belongs to the line below it.
local function line_on(rows, row)
  local low, high = 1, #rows
  if high == 0 then
    return 1, 0
  end
  if row > rows[high] then
    return high, 0
  end
  while low < high do
    local middle = math.floor((low + high) / 2)
    if rows[middle] >= row then
      high = middle
    else
      low = middle + 1
    end
  end
  return low, rows[low] - row
end

-- For lua/taka/diff/pane.lua, which finds the line facing the cursor's.
M.rows_of, M.line_on = rows_of, line_on

-- The other windows of the diff in the tab, lined up with `win`.
function M.follow(win)
  if syncing or not vim.api.nvim_win_is_valid(win) or not vim.wo[win].diff then
    return
  end
  local mine = rows_of(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local top, cursor = (mine[view.topline] or 1) - view.topfill, mine[view.lnum] or 1
  syncing = true
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if other ~= win and vim.wo[other].diff and vim.wo[other].scrollbind then
      local theirs = rows_of(other)
      pcall(vim.api.nvim_win_call, other, function()
        local line, fill = line_on(theirs, top)
        local lnum = line_on(theirs, cursor)
        local now = vim.fn.winsaveview()
        if now.topline ~= line or now.topfill ~= fill or now.lnum ~= lnum then
          vim.fn.winrestview({ topline = line, topfill = fill, lnum = lnum })
        end
      end)
    end
  end
  syncing = false
end

local group = vim.api.nvim_create_augroup("config_diff_scroll", { clear = true })

-- A new diff, or one worked out again, puts the filler lines elsewhere.
vim.api.nvim_create_autocmd({ "DiffUpdated", "WinClosed" }, {
  group = group,
  callback = function()
    ends = {}
  end,
})

vim.api.nvim_create_autocmd("WinScrolled", {
  group = group,
  callback = function()
    -- v:event has an entry for each window that scrolled, keyed by its id.
    for id in pairs(vim.v.event) do
      local win = tonumber(id)
      if win and vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
        return M.follow(win)
      end
    end
  end,
})

return M

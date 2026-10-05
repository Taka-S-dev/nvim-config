-- What the panels on the right share: the pins (lua/taka/pins/), the call
-- tree (lua/taka/call_tree/init.lua), the jump stack (lua/taka/jump_stack.lua),
-- the lit words (lua/taka/words.lua), the svn log (lua/taka/svn/init.lua)
-- and the trace (lua/taka/trace/) are each a snacks picker laid out as a
-- sidebar and drawn as a tree.
local M = {}

-- The layout of a panel: a sidebar on the right with no preview. `extra` goes
-- into its layout, such as a width.
function M.layout(extra)
  return {
    preset = "sidebar",
    preview = false,
    layout = vim.tbl_extend("force", { position = "right" }, extra or {}),
  }
end

-- Whether a panel's key closes it: only where it is in sight, in the tab page
-- shown. A panel is a window of one tab page, and pressed in another its key
-- closed it out of sight and opened nothing; there the panel is closed and
-- made again in the tab page the key was pressed in.
function M.closes(picker)
  local win = picker and not picker.closed and picker.list and picker.list.win and picker.list.win.win
  if not win then
    return false
  end
  local here = vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  picker:close()
  return here
end

-- The guide characters of the file tree, read from snacks when drawn, so the
-- panels look like it.
function M.tree_look()
  local tree = {}
  pcall(function()
    tree = Snacks.picker.config.get().icons.tree
  end)
  return { vertical = tree.vertical or "│ ", middle = tree.middle or "├╴", last = tree.last or "└╴" }
end

-- The rows of `picker` read again with the cursor kept on one of them. The
-- list is emptied and filled again by the finder a moment later, which takes
-- the cursor back to the first row, and the callback find() offers runs before
-- the rows are there. So the list is told beforehand where the cursor goes,
-- `target`, the number of the row once the list is filled, when that is known:
-- the cursor is put there in the same redraw that brings the rows back, and is
-- never seen on the first row in between. Then the row `wanted` picks out is
-- looked for once more when the picker has gone quiet, for the cases the first
-- cannot cover, such as a filter typed in the panel.
function M.refresh(picker, target, wanted)
  if target then
    picker.list:set_target(target, picker.list.top, { force = true })
  end
  picker:find()
  local tries = 0
  local function settle()
    if picker.closed then
      return
    end
    tries = tries + 1
    if picker:is_active() and tries < 100 then
      return vim.defer_fn(settle, 20)
    end
    for index, item in ipairs(picker:items()) do
      if wanted(item) then
        picker.list:view(index)
        return
      end
    end
  end
  vim.defer_fn(settle, 20)
end

return M

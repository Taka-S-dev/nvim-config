-- What the panels on the right share: the pins (lua/config/pins.lua), the call
-- tree (lua/config/call_tree.lua) and the jump stack
-- (lua/config/jump_stack.lua) are each a snacks picker laid out as a sidebar
-- and drawn as a tree.
local M = {}

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

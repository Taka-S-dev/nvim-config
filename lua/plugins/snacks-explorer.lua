-- snacks.nvim's explorer sidebar is a snacks.layout split whose width comes
-- from the "sidebar" preset (40 columns) and is re-applied on every layout
-- update (file change, git refresh, VimResized).
--
-- The windows you actually see and click are floats drawn over that split, and
-- Neovim can't drag-resize a floating window, so the border can't be grabbed
-- with the mouse. Instead: a narrower default, keys to step the width, and
-- Ctrl+drag anywhere in the tree to set it from the mouse column.
--
-- Resizing has to go through both the layout opts and the root window: the
-- root is a split, and `layout:update()` only repositions the floats inside it.
local MIN, MAX = 15, 120

local function set_width(picker, width)
  local layout = picker.layout
  width = math.min(MAX, math.max(MIN, width))
  layout.opts.layout.width = width
  layout.root.opts.width = width
  if layout.root:win_valid() then
    vim.api.nvim_win_set_width(layout.root.win, width)
  end
  layout:update()
end

local function step(delta)
  return function(picker)
    set_width(picker, (picker.layout.root.opts.width or 30) + delta)
  end
end

-- Ctrl+drag: the sidebar sits on the left, so the mouse column is the width.
local function drag(picker)
  local pos = vim.fn.getmousepos()
  if pos.screencol > 0 then
    set_width(picker, pos.screencol)
  end
end

local keys = {
  ["<C-Left>"] = "explorer_narrower",
  ["<C-Right>"] = "explorer_wider",
  -- Also bound for the click that starts the drag: the global <C-LeftMouse>
  -- definition jump in lua/plugins/gtags.lua would otherwise fire on a
  -- Ctrl+click inside the tree.
  ["<C-LeftMouse>"] = { "explorer_drag", mode = { "n", "i" } },
  ["<C-LeftDrag>"] = { "explorer_drag", mode = { "n", "i" } },
}

return {
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        explorer = {
          layout = { layout = { width = 30 } },
          actions = {
            explorer_narrower = step(-5),
            explorer_wider = step(5),
            explorer_drag = drag,
          },
          win = {
            list = { keys = keys },
            input = { keys = keys },
          },
        },
      },
    },
  },
}

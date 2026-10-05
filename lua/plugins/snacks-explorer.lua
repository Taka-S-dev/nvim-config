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

-- The file shown in the code, shown in the tree too: the tree opened down to it
-- and the cursor on it. snacks follows the file on its own, and has a reveal
-- that opens the folders down to it, but both put the cursor there only when
-- their reading of the folders ends after the step that places it; switched to
-- a file in a folder not yet open, the tree opened the folder and left the
-- cursor where it was, rows away, or on the root. So once snacks has gone
-- quiet, the file's row is looked for and the cursor put on it.
local function reveal(file)
  file = vim.fs.normalize(file)
  local explorer = Snacks.explorer.reveal({ file = file })
  local tries = 0
  local function settle()
    tries = tries + 1
    if not explorer or explorer.closed or tries > 100 then
      return
    end
    local item = explorer:current()
    if item and item.file == file then
      return
    end
    if not explorer:is_active() then
      for index, candidate in ipairs(explorer:items()) do
        if candidate.file == file then
          return explorer.list:view(index)
        end
      end
    end
    vim.defer_fn(settle, 20)
  end
  vim.defer_fn(settle, 20)
end

-- After a switch to another file, while the tree is open beside it and not in
-- use. A file outside the tree's folder is left alone: revealing it would move
-- the root of the tree.
local function follow()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  local file = vim.api.nvim_buf_get_name(0)
  if not explorer or explorer.closed or explorer:is_focused() or not explorer:on_current_tab() then
    return
  end
  if file == "" or vim.bo.buftype ~= "" or vim.api.nvim_win_get_config(0).relative ~= "" then
    return
  end
  local item = explorer:current()
  if item and item.file == vim.fs.normalize(file) then
    return
  end
  if require("snacks.explorer.tree"):in_cwd(explorer:cwd(), vim.fs.normalize(file)) then
    reveal(file)
  end
end

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("config_explorer_follow", { clear = true }),
  callback = function()
    -- After snacks' own follow, which runs on the same event, scheduled.
    vim.schedule(follow)
  end,
})

return {
  "folke/snacks.nvim",
  keys = {
    {
      "<leader>fl",
      function()
        reveal(vim.api.nvim_buf_get_name(0))
      end,
      desc = "Show this file in the explorer",
    },
  },
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

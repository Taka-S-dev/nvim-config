-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- VS Code style navigation history: Alt+Left/Right walks the jumplist.
-- <C-o>/<C-i> are the vim-native bindings; these are added for muscle memory.
vim.keymap.set("n", "<A-Left>", "<C-o>", { desc = "Jump back" })
vim.keymap.set("n", "<A-Right>", "<C-i>", { desc = "Jump forward" })

-- Copy the current location as `path:line`, the form grep output, compiler
-- errors and issue trackers all take. Paths use forward slashes and are
-- relative to the cwd, so they stay pasteable as-is; a file outside the cwd
-- falls back to its absolute path rather than an unusable `..\..\` chain.
--
-- In visual mode the line range is copied, for any selection kind -- charwise,
-- linewise and blockwise all report the lines they span. A selection inside a
-- single line stays a single line number instead of `12-12`.
local function location(range)
  local path = vim.fn.expand("%:.")
  if path == "" then
    return nil
  end
  path = path:gsub("\\", "/")
  if not range then
    return ("%s:%d"):format(path, vim.fn.line("."))
  end
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  if first == last then
    return ("%s:%d"):format(path, first)
  end
  return ("%s:%d-%d"):format(path, first, last)
end

local function yank_location(range)
  return function()
    local loc = location(range)
    if not loc then
      vim.notify("This buffer has no file name", vim.log.levels.WARN)
      return
    end
    vim.fn.setreg("+", loc)
    vim.notify(loc)
  end
end

vim.keymap.set("n", "<leader>yp", yank_location(false), { desc = "Yank path:line" })
vim.keymap.set("x", "<leader>yp", yank_location(true), { desc = "Yank path:range" })


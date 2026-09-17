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

-- Reveal the tab markers for as long as they are needed.
--
-- They are off by default because in a tab-indented tree they mark nearly
-- every line (see lua/config/options.lua). Fixing indentation is the case
-- where they are the only way to tell a tab from spaces, so they get a key
-- rather than an edit to the config.
--
-- Turning them on also turns on the markers as a whole: list is window-local
-- and can be off in the window being worked in, and then changing the tab
-- character alone shows nothing while the toggle reports itself as enabled.
Snacks.toggle({
  name = "Tab markers",
  get = function()
    return vim.wo.list and vim.opt.listchars:get().tab ~= "  "
  end,
  set = function(state)
    vim.opt.listchars:append({ tab = state and "> " or "  " })
    if state then
      vim.opt.list = true
    end
  end,
}):map("<leader>uW")

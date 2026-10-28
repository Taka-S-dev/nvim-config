-- The right click on the file tree: a menu for the file or folder clicked,
-- as VS Code's explorer has, in place of the menu for code. The menu every
-- other window opens (Neovim's own, with the definition peek and jump of
-- lua/config/features.lua) offered Peek definition, Inspect and Paste on a
-- file's name, none of which does anything there.
--
-- The menu is one of its own, opened by the tree's right click; the shared
-- one is left as it is, since Neovim turns its entries on and off by name on
-- every right click. Renaming and deleting are left to the tree's keys (r, d):
-- a slip of the mouse there costs more than a copied path.
--
-- Paths are written with forward slashes, as <leader>yp and the tree's own y
-- write them. The relative one is from the cwd, the root of the tree, and a
-- path outside it is given whole rather than as a chain of `..`.
local M = {}

local MENU = "]Explorer"
-- The file or folder the menu was opened on, for the entry chosen.
local target ---@type string?

local function relative(path)
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  return vim.fs.relpath(cwd, path) or path
end

local function copy(text, what)
  vim.fn.setreg("+", text)
  vim.notify(("Copied %s: %s"):format(what, text))
end

-- What each entry does with the path clicked, by the name the menu calls it.
M.actions = {
  copy_path = function(path)
    copy(path, "path")
  end,
  copy_relative = function(path)
    copy(relative(path), "relative path")
  end,
  copy_name = function(path)
    copy(vim.fs.basename(path), "name")
  end,
  -- Windows' Explorer, opened on the folder the file is in with the file
  -- selected; elsewhere the folder is opened, which is as near as the file
  -- managers there come.
  --
  -- Started with uv.spawn, not vim.system: vim.system asks Windows to hide
  -- the window of what it starts (so that no console flashes up), and
  -- Explorer made its window hidden, there and never shown, one more for
  -- each click. The argument is passed as written (verbatim), since Explorer
  -- reads `/select,"path"` itself and a path with a space in it needs the
  -- quotes there, not around the whole argument.
  reveal = function(path)
    if vim.fn.has("win32") == 1 then
      local handle
      handle = vim.uv.spawn("explorer.exe", {
        args = { ('/select,"%s"'):format((path:gsub("/", "\\"))) },
        verbatim = true,
        detached = true,
      }, function()
        if handle and not handle:is_closing() then
          handle:close()
        end
      end)
    else
      vim.ui.open(vim.fs.dirname(path))
    end
  end,
  open = function(path)
    vim.ui.open(path)
  end,
}

-- Runs the entry `name` on the path the menu was opened on.
function M.run(name)
  if target then
    M.actions[name](target)
  end
end

-- For the checks: the path the menu was last opened on.
function M.target()
  return target
end

local function define()
  local entries = {
    { "Copy\\ path", "copy_path" },
    { "Copy\\ relative\\ path", "copy_relative" },
    { "Copy\\ name", "copy_name" },
    { "-1-" },
    { vim.fn.has("win32") == 1 and "Reveal\\ in\\ File\\ Explorer" or "Open\\ containing\\ folder", "reveal" },
    { "Open\\ with\\ default\\ app", "open" },
  }
  for index, entry in ipairs(entries) do
    local rhs = entry[2] and ('<Cmd>lua require("taka.explorer_menu").run("%s")<CR>'):format(entry[2]) or "<Nop>"
    vim.cmd(("anoremenu %d %s.%s %s"):format(index * 10, MENU, entry[1], rhs))
  end
end
define()

-- The tree's right click: the row clicked becomes the current one, as a left
-- click makes it, and the menu opens at the mouse for it. snacks follows the
-- cursor only once a key is done, so the row is moved to here.
--
-- The menu reads its keys through the mappings of the window it opens from,
-- and in the tree's list j, <Down> and Enter are the list's own: opened
-- there, the first key closed the menu and went on to move the list or open
-- the file. So it opens from the code window beside the tree, which maps
-- none of them, and the tree is gone back to once it closes; without
-- autocommands, so the tree does not follow the code's file meanwhile.
function M.open(picker)
  local mouse = vim.fn.getmousepos()
  local list = picker.list
  if list.win:valid() and mouse.winid == list.win.win and mouse.line > 0 then
    vim.api.nvim_set_current_win(list.win.win)
    local top = vim.fn.line("w0", list.win.win)
    list:move(list:row2idx(mouse.line - top + 1), true)
  end
  local item = picker:current()
  if not item then
    return
  end
  target = Snacks.picker.util.path(item)
  local from = vim.api.nvim_get_current_win()
  local main = picker.main
  if main and vim.api.nvim_win_is_valid(main) then
    vim.cmd(("noautocmd call win_gotoid(%d)"):format(main))
  end
  vim.cmd("popup! " .. MENU)
  if vim.api.nvim_win_is_valid(from) then
    vim.cmd(("noautocmd call win_gotoid(%d)"):format(from))
  end
end

return M

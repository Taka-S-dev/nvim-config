-- cscope-style navigation for legacy C using GNU Global (gtags) as backend.
--
-- Why not vim-gutentags? Neovim >=0.9 dropped built-in cscope support, so
-- gutentags's `gtags_cscope` module aborts at load. cscope_maps.nvim
-- reimplements the cscope command set in Lua and talks to `gtags-cscope`
-- directly.
--
-- Why a custom `:!gtags` build binding? cscope_maps's `:Cs db build` always
-- appends `-d <file>::<path>` to the build command for cscope semantics, but
-- the `gtags` binary doesn't accept `-d` — leaving it as the configured
-- builder yields "database build failed".
--
-- Why prefix `<leader>j` (not `<leader>c`)? `<leader>c*` is LazyVim's code
-- namespace (format, action, rename, etc.) and would collide.
--
-- Requires `gtags` on PATH (scoop install global, or winget GNU.GLOBAL).

-- cscope_maps resolves the gtags database once, in setup(), by walking up from
-- the cwd. Open a file from another project -- which the remote-tab workflow in
-- bin/open-in-nvim.cmd does routinely -- and every query still goes to the
-- first project's GTAGS, so it silently returns nothing.
--
-- So pick the database from the file being edited, at query time. Doing it on
-- the query rather than from a BufEnter autocmd keeps the cost off file opening,
-- which matters on machines where security software taxes every file access.
--
-- The window-local cwd has to follow: cscope_maps passes the database to
-- gtags-cscope as a path relative to `getcwd()`, so a database outside the cwd
-- is never found. `lcd` keeps that to this window, and has the side benefit of
-- pointing grep and `<leader>jb` at the project the file belongs to.
local function use_db_of_current_file()
  local ok, cscope = pcall(require, "cscope")
  if not ok then
    return
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return
  end
  local root = cscope.root(vim.fs.dirname(name), "GTAGS")
  if not root or root == vim.fs.normalize(vim.fn.getcwd()) then
    return
  end
  require("cscope.db").update_primary_conn(vim.fs.joinpath(root, "GTAGS"), root)
  vim.cmd.lcd({ vim.fn.fnameescape(root) })
end

-- Wrap a command so the database is in sync before it runs.
local function with_db(cmd)
  return function()
    use_db_of_current_file()
    vim.cmd(cmd)
  end
end

-- Definition jump, kept on gtags but taken off cscope_maps' query path.
--
-- cscope_maps answers every jump by starting gtags-cscope.exe, which starts
-- global.exe, and waits for both with vim.system():wait(), freezing the editor
-- until they exit. Asking global directly drops one process start (117 ms to
-- 36 ms per lookup on the openssl tree), and running it asynchronously means
-- the editor keeps responding however slow process starts are made by security
-- software. Results are kept per project until its GTAGS changes, so a repeated
-- jump starts no process at all.
--
-- A resident gtags-cscope was measured and rejected: it still starts global.exe
-- for every query. Loading every definition up front was rejected too: it is
-- instant on openssl but takes 75 s and 1.3 GB on a Linux kernel tree.
--
-- When gtags has no answer -- no GTAGS for the file, or a source it could not
-- parse -- the jump falls back to ctags.
local definitions = {} ---@type table<string, { mtime: integer, symbols: table<string, table[]> }>

local function symbols_of(root)
  local stat = vim.uv.fs_stat(vim.fs.joinpath(root, "GTAGS"))
  local mtime = stat and stat.mtime.sec or 0
  local project = definitions[root]
  if not project or project.mtime ~= mtime then
    project = { mtime = mtime, symbols = {} }
    definitions[root] = project
  end
  return project.symbols
end

-- `global -axd` prints `name  line  absolute-path  source-line`.
local function parse(output)
  local items = {}
  for line in vim.gsplit(output, "\n", { trimempty = true }) do
    local lnum, file, text = line:gsub("\r$", ""):match("^%S+%s+(%d+)%s+(%S+)%s?(.*)$")
    if lnum then
      items[#items + 1] = { filename = file, lnum = tonumber(lnum), col = 1, text = vim.trim(text) }
    end
  end
  return items
end

local function jump_with_ctags(symbol)
  if not pcall(vim.cmd.tjump, symbol) then
    vim.notify("No definition found for " .. symbol, vim.log.levels.WARN)
  end
end

local function show(symbol, items)
  if #items == 0 then
    jump_with_ctags(symbol)
    return
  end
  -- Record the origin like :tag does, so <C-t> returns here.
  local from = vim.fn.getpos(".")
  from[1] = vim.api.nvim_get_current_buf()
  vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = { { tagname = symbol, from = from } } }, "t")
  if #items == 1 then
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(items[1].filename))
    vim.api.nvim_win_set_cursor(0, { items[1].lnum, 0 })
    vim.cmd("normal! ^")
    return
  end
  vim.fn.setqflist({}, " ", { title = "Definitions of " .. symbol, items = items })
  if Snacks and Snacks.picker then
    Snacks.picker.qflist()
  else
    vim.cmd.copen()
  end
end

local function jump_to_definition(symbol)
  if not symbol or symbol == "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(0)
  local root = name ~= "" and vim.fs.root(name, "GTAGS") or nil
  if not root or vim.fn.executable("global") == 0 then
    jump_with_ctags(symbol)
    return
  end
  local symbols = symbols_of(root)
  if symbols[symbol] then
    show(symbol, symbols[symbol])
    return
  end
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.system({ "global", "-axd", symbol }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      local items = result.code == 0 and parse(result.stdout or "") or {}
      symbols[symbol] = items
      -- Jump only if the user is still where they asked from.
      if vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf then
        show(symbol, items)
      end
    end)
  end)
end

local function selected_text()
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return vim.trim(region[1] or "")
end

-- Ctrl+click: move the cursor to what was clicked, then jump. Vim's built-in
-- <C-LeftMouse> runs `:tag <cword>` directly and bypasses any remap of <C-]>.
local function jump_at_mouse()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= 0 and pos.line > 0 then
    vim.api.nvim_set_current_win(pos.winid)
    vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.column - 1, 0) })
  end
  jump_to_definition(vim.fn.expand("<cword>"))
end

return {
  "dhananjaylatkar/cscope_maps.nvim",
  event = "VeryLazy",
  init = function()
    -- C identifiers are case-sensitive. With the default "followic" and
    -- LazyVim's ignorecase, the ctags fallback treats SSL_new and ssl_new as the
    -- same tag and stops to ask which one was meant.
    vim.opt.tagcase = "match"
  end,
  keys = {
    { "<C-]>", function() jump_to_definition(vim.fn.expand("<cword>")) end, desc = "Jump to definition" },
    { "<C-]>", function() jump_to_definition(selected_text()) end, desc = "Jump to definition", mode = "x" },
    { "<C-LeftMouse>", jump_at_mouse, desc = "Jump to definition (Ctrl+click)", mode = { "n", "x" } },
    -- The symbol is deliberately omitted: `:Cscope find <op>` falls back to
    -- the word under the cursor, or the visual selection in visual mode.
    -- Passing <C-r><C-w> here does not work, because <cmd> runs the command
    -- without entering command-line mode, so it arrives as a literal "^R^W".
    { "<leader>jb", "<cmd>!gtags<cr>", desc = "Build gtags DB (cwd)" },
    { "<leader>js", with_db("Cscope find s"), desc = "Find this symbol", mode = { "n", "v" } },
    { "<leader>jg", with_db("Cscope find g"), desc = "Find global definition", mode = { "n", "v" } },
    { "<leader>jc", with_db("Cscope find c"), desc = "Find callers", mode = { "n", "v" } },
    { "<leader>jt", with_db("Cscope find t"), desc = "Find this text string", mode = { "n", "v" } },
    { "<leader>jf", with_db("Cscope find f"), desc = "Find file", mode = { "n", "v" } },
    { "<leader>ji", with_db("Cscope find i"), desc = "Find files #including this", mode = { "n", "v" } },
  },
  opts = {
    disable_maps = true,
    cscope = {
      -- cscope_maps binds <C-]> to :Cstag from its own setup, which runs after
      -- the keys above and would win.
      tag = { keymap = false },
      db_file = "./GTAGS",
      exec = "gtags-cscope",
      picker = "snacks",
      skip_picker_for_single_result = true,
      project_rooter = {
        enable = true,
      },
    },
  },
}

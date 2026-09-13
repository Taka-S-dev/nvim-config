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
-- first project's GTAGS, so it silently returns nothing. `<C-]>` hides this by
-- falling back to ctags; `Cscope find` has no fallback and just reports
-- "no results".
--
-- So pick the database from the file being edited, at query time. Doing it on
-- the jump rather than from a BufEnter autocmd keeps the cost off file opening,
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

-- Ctrl+click: move the cursor to what was clicked, then jump. Vim's built-in
-- <C-LeftMouse> runs `:tag <cword>` directly and bypasses any remap of <C-]>,
-- so it would fall back to the tag-file system and raise E426.
local function cstag_at_mouse()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= 0 and pos.line > 0 then
    vim.api.nvim_set_current_win(pos.winid)
    vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.column - 1, 0) })
  end
  use_db_of_current_file()
  vim.cmd("Cstag")
end

return {
  "dhananjaylatkar/cscope_maps.nvim",
  event = "VeryLazy",
  keys = {
    -- The symbol is deliberately omitted: `:Cscope find <op>` falls back to
    -- the word under the cursor, or the visual selection in visual mode.
    -- Passing <C-r><C-w> here does not work, because <cmd> runs the command
    -- without entering command-line mode, so it arrives as a literal "^R^W".
    --
    { "<C-]>", with_db("Cstag"), desc = "Jump to definition (Cstag)", mode = { "n", "v" } },
    { "<C-LeftMouse>", cstag_at_mouse, desc = "Cstag (Ctrl+click)", mode = { "n", "v" } },
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
      -- the keys above and would win. Ours has to be the only one: it syncs the
      -- database to the current file first.
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

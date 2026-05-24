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
return {
  "dhananjaylatkar/cscope_maps.nvim",
  event = "VeryLazy",
  keys = {
    -- Vim's built-in <C-LeftMouse> runs `:tag <cword>` directly and bypasses
    -- any remap of <C-]>, so Ctrl+click falls back to the tag-file system and
    -- raises E426. Route it through :Cstag like <C-]> does.
    { "<C-LeftMouse>", "<LeftMouse><cmd>Cstag<cr>", desc = "Cstag (Ctrl+click)", mode = { "n", "v" } },
    { "<leader>jb", "<cmd>!gtags<cr>", desc = "Build gtags DB (cwd)" },
    { "<leader>js", "<cmd>Cscope find s <C-r><C-w><cr>", desc = "Find this symbol", mode = { "n", "v" } },
    { "<leader>jg", "<cmd>Cscope find g <C-r><C-w><cr>", desc = "Find global definition", mode = { "n", "v" } },
    { "<leader>jc", "<cmd>Cscope find c <C-r><C-w><cr>", desc = "Find callers", mode = { "n", "v" } },
    { "<leader>jt", "<cmd>Cscope find t <C-r><C-w><cr>", desc = "Find this text string", mode = { "n", "v" } },
    { "<leader>jf", "<cmd>Cscope find f <C-r><C-w><cr>", desc = "Find file", mode = { "n", "v" } },
    { "<leader>ji", "<cmd>Cscope find i <C-r><C-w><cr>", desc = "Find files #including this", mode = { "n", "v" } },
  },
  opts = {
    disable_maps = true,
    cscope = {
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

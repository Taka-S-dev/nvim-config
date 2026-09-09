-- vim-gutentags: auto-generate and maintain ctags `tags` files in the
-- background. Acts as a fallback for cscope_maps + gtags in projects
-- where gtags can't index everything (Shift-JIS-encoded sources,
-- non-standard file extensions, exotic dialects of legacy C, etc.).
--
-- cscope_maps's :Cstag tries gtags first and falls back to vim's tag
-- system on miss, so both can coexist transparently: gtags wins where
-- it works, ctags catches the rest.
--
-- Requires Universal Ctags on PATH. The Exuberant Ctags 5.8 (2009)
-- bundled with Strawberry Perl is too old; install a current build:
--   winget install universal-ctags.ctags  (or `scoop install ctags`)
return {
  "ludovicchabant/vim-gutentags",
  event = "VeryLazy",
  init = function()
    vim.g.gutentags_modules = { "ctags" }
    -- keep tags out of the project tree
    vim.g.gutentags_cache_dir = vim.fn.stdpath("cache") .. "/gutentags"

    -- Strawberry Perl puts Exuberant Ctags 5.8 ahead of scoop on PATH, so
    -- pin the Universal Ctags shim instead of trusting `ctags` resolution.
    local uctags = vim.fn.expand("~/scoop/shims/ctags.exe")
    if vim.fn.executable(uctags) == 1 then
      vim.g.gutentags_ctags_executable = uctags
    end

    -- A directory that only groups unrelated source trees must not become
    -- one project: indexing it takes minutes and produces a tags file over
    -- 1 GB. Put an empty `.gutctags-root` in the real project directory to
    -- mark it as the root. Directories to exclude are machine-specific, so
    -- they are read from lua/config/local.lua (git-ignored) if set there.
    vim.g.gutentags_project_root = { ".gutctags-root" }
    vim.g.gutentags_exclude_project_root = vim.g.gutentags_exclude_project_root or {}
    -- Only index when a tags file already exists or was explicitly requested
    -- (:GutentagsUpdate); no silent full scans on first open.
    vim.g.gutentags_generate_on_missing = 0
    vim.g.gutentags_generate_on_new = 0
  end,
}

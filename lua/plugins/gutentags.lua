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
  end,
}

-- vim-gutentags: auto-generate and maintain ctags `tags` files in the
-- background. Acts as a fallback for cscope_maps + gtags in projects
-- where gtags can't index everything (Shift-JIS-encoded sources,
-- non-standard file extensions, exotic dialects of legacy C, etc.).
--
-- The definition jump in lua/plugins/gtags.lua asks gtags first and falls
-- back to vim's tag system on a miss, so both can coexist transparently:
-- gtags wins where it works, ctags catches the rest.
--
-- Requires Universal Ctags on PATH. The Exuberant Ctags 5.8 (2009)
-- bundled with Strawberry Perl is too old; install a current build:
--   winget install universal-ctags.ctags  (or `scoop install ctags`)
return {
  "ludovicchabant/vim-gutentags",
  event = "VeryLazy",
  init = function()
    vim.g.gutentags_modules = { "ctags" }
    -- The tags file goes in the project root, where Vim looks for it without
    -- being told and where GTAGS already is. A cache directory kept the tree
    -- clean, but nobody could say where the file was, the cache sits under the
    -- Windows temp directory, which gets cleaned, and no other tool found it.
    -- ripgreprc keeps the file out of search results.

    -- Strawberry Perl puts Exuberant Ctags 5.8 ahead of scoop on PATH, so
    -- pin the Universal Ctags shim instead of trusting `ctags` resolution.
    local uctags = vim.fn.expand("~/scoop/shims/ctags.exe")
    if vim.fn.executable(uctags) == 1 then
      vim.g.gutentags_ctags_executable = uctags
    end

    -- A directory that only groups unrelated source trees must not become
    -- one project: indexing it takes minutes and produces a tags file over
    -- 1 GB. gutentags takes a directory under version control (.git and the
    -- like) for a project on its own; a tree that was only unpacked needs an
    -- empty `.gutctags-root` in its root. Directories to exclude are
    -- machine-specific, so they are read from lua/config/local.lua
    -- (git-ignored) if set there.
    vim.g.gutentags_project_root = { ".gutctags-root" }
    vim.g.gutentags_exclude_project_root = vim.g.gutentags_exclude_project_root or {}
    -- Only index when a tags file already exists or was explicitly requested
    -- (:GutentagsUpdate); no silent full scans on first open.
    vim.g.gutentags_generate_on_missing = 0
    vim.g.gutentags_generate_on_new = 0

    -- The ctags fallback lands on the first match, so a stale copy in the index
    -- is a wrong landing, not just noise. Editors that keep local history (.history/) and
    -- backup files put whole duplicate sources in the tree; the index files of
    -- the other tools are never source.
    vim.g.gutentags_ctags_exclude = {
      ".git",
      ".history",
      "*.BAK",
      "*.bak",
      "*~",
      "GTAGS",
      "GRTAGS",
      "GPATH",
      "cscope.out",
      "tags",
    }
  end,
  config = function()
    -- gutentags' own update_tags.cmd writes its progress to CON, the console
    -- itself, unless it is given a log file, so every index run and every save
    -- in a project with a tags file printed lines over the editor's screen.
    -- bin/gutentags/update_tags.cmd calls it with the log sent to NUL; see that
    -- file. The plugin sets the directory unconditionally when it loads, so it
    -- is replaced here, after the load, and the ctags module is read again in
    -- case it had already taken the old path.
    local wrapper_dir = vim.fn.stdpath("config") .. "\\bin\\gutentags\\"
    if vim.fn.has("win32") == 1 and vim.fn.filereadable(wrapper_dir .. "update_tags.cmd") == 1 then
      vim.env.GUTENTAGS_PLAT_DIR = vim.g.gutentags_plat_dir
      vim.g.gutentags_plat_dir = wrapper_dir
      vim.cmd("runtime! autoload/gutentags/ctags.vim")
    end

    -- With its output gone a ctags run shows nothing at all, so its start and
    -- end go to the statusline (lua/config/activity.lua). Updating is fired
    -- even when no job was started, and Updated once per job, so both check
    -- what is actually in progress: a spinner that nothing ends would spin on.
    local finished
    local group = vim.api.nvim_create_augroup("gutentags_activity", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GutentagsUpdating",
      callback = function()
        if not finished and #vim.fn["gutentags#inprogress"]() > 0 then
          finished = require("config.activity").begin("ctags: indexing")
        end
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "GutentagsUpdated",
      callback = function()
        if finished and #vim.fn["gutentags#inprogress"]() == 0 then
          local took = finished("done")
          finished = nil
          if took >= 3000 then
            vim.notify(("ctags: index done in %.0f s"):format(took / 1000))
          end
        end
      end,
    })
  end,
}

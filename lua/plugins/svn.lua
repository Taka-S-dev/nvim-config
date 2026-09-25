-- Change marks for a Subversion working copy: the lines added, changed and
-- removed since the last update show in the sign column, as gitsigns shows
-- them for a git checkout, and ]h / [h go from one change to the next.
--
-- gitsigns knows git only. vim-signify knows several systems; here it is kept
-- to svn alone, so in a git checkout the two never mark the same file. It runs
-- svn diff against the working copy's own base, never the server, when a file
-- is read and when it is written. Nothing happens in a tree that is not a
-- working copy or on a machine without svn on the PATH.
--
-- Loaded at start: the plugin is a handful of autocmds on reading a buffer,
-- and a buffer read before they exist gets no marks until it is read again.
return {
  "mhinz/vim-signify",
  lazy = false,
  init = function()
    vim.g.signify_skip = { vcs = { allow = { "svn" } } }
  end,
  keys = {
    -- The same keys gitsigns gives a git checkout, which it maps per buffer
    -- and so wins where both could apply.
    { "]h", "<plug>(signify-next-hunk)", desc = "Next change (svn)" },
    { "[h", "<plug>(signify-prev-hunk)", desc = "Previous change (svn)" },
    { "<leader>ghp", "<cmd>SignifyHunkDiff<cr>", desc = "Preview change (svn)" },
    { "<leader>ghr", "<cmd>SignifyHunkUndo<cr>", desc = "Undo change (svn)" },
  },
}

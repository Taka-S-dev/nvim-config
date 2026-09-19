-- A checkout made with core.autocrlf=true has CRLF line endings on disk while
-- git keeps LF, and git itself calls such a file unchanged. Where the tree also
-- has an .editorconfig asking for LF, as the Linux tree does, Neovim switches
-- the buffer to unix line endings after reading it; gitsigns then compares
-- those lines against text it expects to carry CRLF, and every line differs.
-- A file nobody had touched showed the change bar, which LazyVim draws to the
-- right of the line numbers, down its whole length.
--
-- A difference that is only whitespace at the end of a line is left out of the
-- comparison. A trailing space someone adds still shows, through the listchars
-- marker (lua/config/options.lua); what is given up is its change bar. The
-- other diff options keep their defaults: gitsigns merges this table into them.
return {
  "lewis6991/gitsigns.nvim",
  opts = {
    diff_opts = { ignore_whitespace_change_at_eol = true },
  },
}

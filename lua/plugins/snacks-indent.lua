-- snacks.indent draws a vertical line through the block under the cursor, in
-- a brighter blue than the code beside it and in every window rather than the
-- focused one. LazyVim turns it on by default; Neovim has no such thing, and
-- other distributions do not add one.
--
-- The indentation guides stay: they sit far enough back to read as structure.
-- It is the scope line that reads as an edit marker at the left edge of the
-- text, which is where a sign or a diff marker belongs.
return {
  "folke/snacks.nvim",
  opts = {
    indent = {
      scope = { enabled = false },
    },
  },
}

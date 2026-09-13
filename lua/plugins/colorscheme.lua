-- tokyonight draws window separators in #1b1d2b on a #222436 background --
-- a contrast ratio of 1.09:1, which is invisible in practice. With
-- `laststatus = 3` there is one global statusline, so that line is the only
-- thing marking a horizontal split, and splits read as one continuous buffer.
--
-- The comment color is the darkest entry in the palette that still clears the
-- 3:1 contrast WCAG asks of non-text UI elements (3.11:1 here). Brighter
-- options exist, but a separator that outshines the code is its own problem.
return {
  "folke/tokyonight.nvim",
  opts = {
    on_highlights = function(hl, c)
      hl.WinSeparator = { fg = c.comment }
      -- The indentation guides ship at 1.56:1 against the editor background,
      -- which is not enough to follow a brace pair down a screen of Lua
      -- tables. They are decoration rather than a control, so they stay under
      -- the 3:1 the separator needs, but far enough up to be readable.
      hl.SnacksIndent = { fg = c.dark3 }
    end,
  },
}

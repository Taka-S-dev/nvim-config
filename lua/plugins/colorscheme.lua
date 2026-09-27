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
      -- The scope line pinned with <leader>jl (lua/config/scope_pin.lua), in
      -- orange so that beside the blue line that follows the cursor there is
      -- no doubt which one was pinned; orange is otherwise used for numbers
      -- only, so the line does not blend into the code.
      hl.ScopePin = { fg = c.orange }
      -- A changed line in a diff ships as a tint of the background so faint
      -- (#252a3f on #222436) that the cursor line outshines it, and the text
      -- changed within it is only a little stronger. Any blue reads as the
      -- cursor line, itself a blue grey, so both are amber instead, apart from
      -- the green of an added line and the red of a deleted one. They are set
      -- rather than blended from the palette's yellow: on this blue background
      -- a blend comes out grey. The line stands 1.33:1 off the background and
      -- apart from the cursor line by hue. On the changed text, plain code
      -- reads at 4.66:1, names of functions and types at 3.0:1 or so, and a
      -- comment at 1.4:1: the comment colour is kept faint everywhere, and a
      -- background light enough to mark the change is too light for it.
      hl.DiffChange = { bg = "#3d3a22" }
      hl.DiffText = { bg = "#635a2a" }
    end,
  },
}

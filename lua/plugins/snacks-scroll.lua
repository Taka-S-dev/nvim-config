-- No smooth scrolling in a diff, or beside a blame: a jump there lands at
-- once, as in WinMerge.
--
-- Smooth scrolling moves only the window scrolled, a step at a time. In a diff
-- the other side and the strip beside it (lua/taka/diff/scroll.lua and
-- lua/taka/diff/map.lua) follow each step only after it is on screen, so
-- through a long jump, such as a click on the strip, they trail a step behind
-- and the view stutters. A file and its blame beside it
-- (lua/taka/svn/blame.lua) are kept level the same way, and stuttered the
-- same way. Everywhere else the scrolling is as LazyVim sets it.
return {
  "folke/snacks.nvim",
  opts = {
    scroll = {
      filter = function(buf)
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          if vim.wo[win].diff or vim.w[win].svn_blame then
            return false
          end
        end
        -- The rest as snacks has it.
        return vim.g.snacks_scroll ~= false and vim.b[buf].snacks_scroll ~= false and vim.bo[buf].buftype ~= "terminal"
      end,
    },
  },
}

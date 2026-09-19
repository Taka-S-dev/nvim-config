-- Show what is running in the background: a gtags lookup, an index being built
-- or updated, a ctags run. lua/config/activity.lua keeps the list and puts the
-- text to draw in vim.g.background_activity: a spinner, the label and the
-- seconds gone while something runs, then what it took for two seconds after.
-- Nothing is shown when nothing runs.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function()
        return vim.g.background_activity
      end,
      cond = function()
        return vim.g.background_activity ~= nil
      end,
      color = function()
        return { fg = Snacks.util.color("DiagnosticInfo") }
      end,
    })
  end,
}

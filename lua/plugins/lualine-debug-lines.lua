-- Show how many debug lines are left in the project, `DBG 3`, so they are
-- seen before a commit. lua/taka/debug_lines.lua counts them and puts the
-- text in vim.g.debug_lines_count. Nothing is shown when there are none.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function()
        return vim.g.debug_lines_count
      end,
      cond = function()
        return vim.g.debug_lines_count ~= nil
      end,
      color = function()
        return { fg = Snacks.util.color("DiagnosticWarn") }
      end,
    })
  end,
}

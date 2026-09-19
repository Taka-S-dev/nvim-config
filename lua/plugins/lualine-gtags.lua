-- Show what gtags is looking up, and what the last lookup cost.
--
-- lua/plugins/gtags.lua puts the text in vim.g.gtags_lookup: the name while
-- global has not answered, then the time the answer took and where it came
-- from, cleared again two seconds later. So every lookup leaves a trace here,
-- a quick one included, and a slow global.exe start reads as work in progress.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function()
        return "gtags: " .. vim.g.gtags_lookup
      end,
      cond = function()
        return vim.g.gtags_lookup ~= nil
      end,
      color = function()
        return { fg = Snacks.util.color("DiagnosticInfo") }
      end,
    })
  end,
}

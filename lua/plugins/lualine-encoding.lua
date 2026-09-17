-- Show the file's encoding in the statusline, but only when it isn't UTF-8.
--
-- With cp932 in 'fileencodings' a legacy file now opens silently and
-- looks like any other buffer, which is the point — and also the risk: typing a
-- character that cp932 can't represent (⇒, ①-style vendor glyphs from another
-- code page, emoji) fails at :write with E513, long after the edit. A marker in
-- the statusline is the cheap warning that this buffer round-trips through
-- Shift-JIS. UTF-8 buffers, being the normal case, stay unmarked.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function()
        return vim.bo.fileencoding
      end,
      cond = function()
        local fenc = vim.bo.fileencoding
        return fenc ~= "" and fenc ~= "utf-8"
      end,
      color = function()
        return { fg = Snacks.util.color("DiagnosticWarn") }
      end,
    })
  end,
}

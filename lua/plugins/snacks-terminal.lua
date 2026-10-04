-- The terminal of <C-/> opens again at the height it was left at. Hidden and
-- shown again, snacks makes its window anew at the height the options give, so
-- a terminal made taller, or shorter, went back to four tenths of the editor
-- every time. The height it has when its window closes is kept for the
-- session, and the options hand it back; a restart begins at four tenths
-- again.
-- The terminal's height when its window last closed, in rows.
local height ---@type integer?

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("config_terminal_height", { clear = true }),
  callback = function(event)
    local win = tonumber(event.match)
    if
      win
      and vim.api.nvim_win_is_valid(win)
      and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_terminal"
      and vim.api.nvim_win_get_config(win).relative == ""
    then
      height = vim.api.nvim_win_get_height(win)
    end
  end,
})

return {
  "folke/snacks.nvim",
  opts = {
    terminal = {
      win = {
        height = function()
          -- Until it is closed once, the split's own share of the editor.
          return height or 0.4
        end,
      },
    },
  },
}

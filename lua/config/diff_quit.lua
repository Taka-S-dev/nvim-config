-- q anywhere in a comparison ends it, whichever window the cursor is in and
-- however the comparison was opened:
--
--   the svn log's tab (<leader>vh)  the tab closes, the list and pane with it
--   a file against its base (<leader>vd, git), or any other diff
--                                   the sides that are no file close, and a
--                                   file's own window leaves diff mode and
--                                   stays; a side with changes not yet
--                                   written back (git's index) stays too
--
-- Everywhere else q records a macro, as it always does. Inside a comparison
-- it does not: that is the price of one key to leave every kind of it.
local M = {}

-- Whether the cursor is in a comparison: a window in diff mode, or the pane
-- below one (lua/config/diff_pane.lua).
function M.here()
  return vim.wo.diff or vim.bo.filetype == "diffpane"
end

function M.close()
  if vim.t.svn_log then
    return require("config.svn").close_log(vim.api.nvim_get_current_tabpage())
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      local buf = vim.api.nvim_win_get_buf(win)
      -- A side that is no file of its own (a revision, git's index) closes,
      -- unless it holds changes not yet written back.
      if vim.bo[buf].buftype ~= "" and not vim.bo[buf].modified and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        pcall(vim.api.nvim_win_close, win, true)
      else
        vim.api.nvim_win_call(win, function()
          vim.cmd("diffoff")
        end)
      end
    end
  end
end

-- An expression mapping may not close windows (E565), so the closing comes
-- after it; outside a comparison the key is handed back as q.
vim.keymap.set("n", "q", function()
  if not M.here() then
    return "q"
  end
  vim.schedule(M.close)
  return ""
end, { expr = true, desc = "End the comparison, or record a macro" })

return M

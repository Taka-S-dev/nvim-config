-- q anywhere in a comparison ends it, whichever window the cursor is in and
-- however the comparison was opened:
--
--   a tab a tool set up for a comparison and named a closer for (on_quit),
--   as the svn log's tab (<leader>vh) does
--                                   the closer, which there shuts the tab
--   a file against its base (<leader>vd, git), or any other diff
--                                   the sides that are no file close, and a
--                                   file's own window leaves diff mode and
--                                   stays; a side with changes not yet
--                                   written back (git's index) stays too
--
-- Everywhere else q records a macro, as it always does. Inside a comparison
-- it does not: that is the price of one key to leave every kind of it.
local M = {}

-- The closers named by tools for tabs of their own, by tab.
local closers = {}

-- q in `tab` calls `close(tab)` instead of ending a diff, for a tool that
-- lays a comparison out in a tab of its own and knows how to put it away.
function M.on_quit(tab, close)
  closers[tab] = close
end

vim.api.nvim_create_autocmd("TabClosed", {
  group = vim.api.nvim_create_augroup("config_diff_quit", { clear = true }),
  callback = function()
    for tab in pairs(closers) do
      if not vim.api.nvim_tabpage_is_valid(tab) then
        closers[tab] = nil
      end
    end
  end,
})

-- Whether the cursor is in a comparison: a window in diff mode, or the pane
-- below one (lua/taka/diff/pane.lua).
function M.here()
  return vim.wo.diff or vim.bo.filetype == "diffpane"
end

function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  if closers[tab] then
    return closers[tab](tab)
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

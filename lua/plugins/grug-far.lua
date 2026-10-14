-- The results of grug-far (<leader>sr) searched again when a file is saved,
-- while its window is open. They are what rg found on the disk when the search
-- was made, and a line deleted from a file stayed in the list until it was
-- searched again by hand; an editor's search follows the file instead. A
-- change not yet saved is not seen, rg reading the disk; :wa searches once.
local pending = false

local function search_again()
  pending = false
  if not package.loaded["grug-far"] then
    return
  end
  local grug_far = require("grug-far")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "grug-far" then
      local instance = grug_far.get_instance(buf)
      if instance then
        instance:search()
      end
    end
  end
end

return {
  "MagicDuck/grug-far.nvim",
  init = function()
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup("config_grug_far_refresh", { clear = true }),
      callback = function()
        if not pending then
          pending = true
          vim.schedule(search_again)
        end
      end,
    })
  end,
}

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

-- One search, kept when it is put away and brought back as it was, as VS
-- Code's search panel is: its text, its paths, its filter and its results.
-- LazyVim's <leader>sr opened a fresh one each time, gone with its window, and
-- the paths a search had been narrowed to were typed again at every opening,
-- though one module is mostly searched again and again. <leader>sr and q put
-- it away and bring it back; grug-far's own close (\c) ends it, and the next
-- <leader>sr starts afresh.
local NAME = "main"
-- The folder of the file <leader>sr was last pressed in, for \d.
local origin

-- The text selected, when <leader>sr is pressed on a selection; Visual mode is
-- left.
local function selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return table.concat(lines, "\n")
end

local function toggle()
  local grug_far = require("grug-far")
  local file = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or ""
  if file ~= "" then
    origin = vim.fs.dirname(vim.fs.normalize(file))
  end
  local text = selection()
  if not grug_far.has_instance(NAME) then
    -- The first of a session: the filter of the file's kind, as LazyVim gave.
    local ext = file ~= "" and vim.fn.fnamemodify(file, ":e") or ""
    grug_far.open({
      instanceName = NAME,
      visualSelectionUsage = "ignore",
      prefills = { search = text, filesFilter = ext ~= "" and "*." .. ext or nil },
    })
    return
  end
  local open = grug_far.is_instance_open(NAME)
  if open and not text then
    return grug_far.toggle_instance({ instanceName = NAME })
  end
  if not open then
    grug_far.toggle_instance({ instanceName = NAME })
  end
  if text then
    -- The text selected is looked for; the paths and the filter stay.
    grug_far.update_instance_prefills(NAME, { search = text }, false)
  else
    -- Brought back: searched again, files having been saved meanwhile.
    grug_far.get_instance(NAME):search()
  end
end

-- \d in the search: its paths set to the folder of the file it was opened
-- from, as from the cwd, the module being read.
local function paths_to_origin()
  if not origin then
    return vim.notify("No file to take a folder from", vim.log.levels.WARN)
  end
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local path = vim.fs.relpath(cwd, origin) or origin
  path = path == "." and "./" or path .. "/"
  require("grug-far").update_instance_prefills(NAME, { paths = path }, false)
end

return {
  "MagicDuck/grug-far.nvim",
  keys = {
    { "<leader>sr", toggle, mode = { "n", "x" }, desc = "Search and Replace (kept)" },
  },
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
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("config_grug_far_kept", { clear = true }),
      pattern = "grug-far",
      callback = function(event)
        vim.schedule(function()
          local grug_far = package.loaded["grug-far"]
          -- Only the kept search: a grug-far opened otherwise is left as it
          -- is. get_instance raises an error for a name no search has.
          if not (grug_far and grug_far.has_instance(NAME)) then
            return
          end
          if grug_far.get_instance(event.buf) ~= grug_far.get_instance(NAME) then
            return
          end
          -- Kept, but not among the files: not listed, so it stays out of the
          -- tabs of open buffers.
          vim.bo[event.buf].buflisted = false
          -- q a step later again: LazyVim maps q in grug-far to close the
          -- window and delete the buffer (close_with_q), on the same
          -- FileType and after this, and its q, set last, ended the search.
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(event.buf) then
              vim.keymap.set("n", "q", toggle, { buffer = event.buf, desc = "Put the search away (kept)" })
            end
          end)
          vim.keymap.set("n", "<localleader>d", paths_to_origin, {
            buffer = event.buf,
            desc = "Search in the folder of the file it was opened from",
          })
        end)
      end,
    })
  end,
}

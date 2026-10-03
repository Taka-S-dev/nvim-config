-- The text selected, lit where else it stands on screen, while it is selected,
-- as VS Code lights a selection's other occurrences. It is matched as it
-- stands, case and all, with no character in it taken for a pattern, so
-- `[17]` finds `[17]`.
--
-- Only a selection made with v, within one line and of two characters or
-- more that are not all blanks: a selection over lines, by lines or a block
-- is for an edit, and one character matches everywhere. Only the lines on
-- screen are looked through, so the length of the file does not matter.
--
-- The colour is the one a language server's references to the word under the
-- cursor are lit in (LspReferenceText): the same thing elsewhere.
local M = {}

local ns = vim.api.nvim_create_namespace("config_selection_matches")
local lit = {}

local function clear()
  for buf in pairs(lit) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  lit = {}
end

-- The selection as text, with the line and the byte columns (1-based, the end
-- included) it takes, when it is one that is lit.
local function selection()
  if vim.fn.mode() ~= "v" then
    return nil
  end
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  if from[2] ~= to[2] then
    return nil
  end
  local region = vim.fn.getregionpos(from, to, { type = "v" })[1]
  if not region then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(0, from[2] - 1, from[2], false)[1] or ""
  local first, last = region[1][3], region[2][3]
  local text = line:sub(first, last)
  if vim.fn.strchars(text) < 2 or not text:find("%S") then
    return nil
  end
  return text, from[2], first
end

-- The places the selection stands elsewhere on screen lit, and the last ones
-- put out.
function M.update()
  clear()
  local text, row, col = selection()
  if not text then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local top, bottom = vim.fn.line("w0"), vim.fn.line("w$")
  for number, line in ipairs(vim.api.nvim_buf_get_lines(buf, top - 1, bottom, false)) do
    local lnum = top + number - 1
    local at = 1
    while true do
      local first, last = line:find(text, at, true)
      if not first then
        break
      end
      -- The selection itself is lit already.
      if not (lnum == row and first == col) then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, first - 1, {
          end_col = last,
          hl_group = "SelectionMatch",
        })
        lit[buf] = true
      end
      at = last + 1
    end
  end
end

-- For the checks: the places lit, as "line:column".
function M.marks()
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
    out[#out + 1] = ("%d:%d"):format(mark[2] + 1, mark[3] + 1)
  end
  return out
end

local function defaults()
  vim.api.nvim_set_hl(0, "SelectionMatch", { link = "LspReferenceText", default = true })
end
defaults()

local group = vim.api.nvim_create_augroup("config_selection_matches", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = defaults })
-- A selection is made, changed, scrolled over, and given up.
vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
  group = group,
  callback = function()
    if next(lit) or vim.fn.mode() == "v" then
      M.update()
    end
  end,
})
vim.api.nvim_create_autocmd("ModeChanged", {
  group = group,
  pattern = "*:*",
  callback = M.update,
})

return M

-- The word under the cursor, lit where else it stands on screen once the
-- cursor rests on it, as VS Code lights a word's other occurrences. LazyVim
-- does this through a language server (Snacks words); a C tree read here has
-- none attached, and nothing was lit. Where a server that lights references
-- is attached, it is left to it.
--
-- The word is matched whole and with its case, so ssl does not light the ssl
-- of ssl_new. It is the same spelling, not the same thing: a local of the same
-- name in another function is lit too. Only a name of two characters or more,
-- in Normal mode, in a buffer that holds a file; and only when it stands
-- somewhere else on screen as well, so moving through the text does not light
-- one word after another. Only the lines on screen are looked through, as for
-- the selection (lua/taka/selection_matches.lua), in the same colour.
local M = {}

local ns = vim.api.nvim_create_namespace("config_cursor_word")
-- Snacks waits as long before it lights the references a server gives.
local DELAY = 200

local lit = {} ---@type table<integer, boolean>
local timer = vim.uv.new_timer()

local function clear()
  for buf in pairs(lit) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  lit = {}
end

-- The word to light, or nil where none is.
local function word()
  if vim.api.nvim_get_mode().mode ~= "n" or vim.bo.buftype ~= "" then
    return nil
  end
  if #vim.lsp.get_clients({ bufnr = 0, method = "textDocument/documentHighlight" }) > 0 then
    return nil
  end
  local text = vim.fn.expand("<cword>")
  if #text < 2 or not text:match("^[%a_][%w_]*$") then
    return nil
  end
  -- <cword> also gives the next word on the line when the cursor is before
  -- it, on a blank or a bracket; only a word the cursor is on is lit.
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local line = vim.api.nvim_get_current_line()
  if not line:sub(col, col):match("[%w_]") then
    return nil
  end
  return text
end

-- The places the word under the cursor stands on screen lit, and the last
-- ones put out.
function M.update()
  clear()
  local text = word()
  if not text then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local pattern = "%f[%w_]" .. vim.pesc(text) .. "%f[^%w_]"
  local top, bottom = vim.fn.line("w0"), vim.fn.line("w$")
  local found = {}
  for number, line in ipairs(vim.api.nvim_buf_get_lines(buf, top - 1, bottom, false)) do
    local at = 1
    while true do
      local first, last = line:find(pattern, at)
      if not first then
        break
      end
      found[#found + 1] = { top + number - 2, first - 1, last }
      at = last + 1
    end
  end
  if #found < 2 then
    return
  end
  for _, place in ipairs(found) do
    vim.api.nvim_buf_set_extmark(buf, ns, place[1], place[2], { end_col = place[3], hl_group = "CursorWordMatch" })
  end
  lit[buf] = true
end

-- For the checks: the places lit, as "line:column".
function M.marks()
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
    out[#out + 1] = ("%d:%d"):format(mark[2] + 1, mark[3] + 1)
  end
  return out
end

M.DELAY = DELAY

-- Put out at once when the cursor moves, and lit again once it rests, so a
-- word passed over on the way is never lit.
local function later()
  clear()
  timer:stop()
  timer:start(DELAY, 0, vim.schedule_wrap(M.update))
end

local function defaults()
  vim.api.nvim_set_hl(0, "CursorWordMatch", { link = "LspReferenceText", default = true })
end
defaults()

local group = vim.api.nvim_create_augroup("config_cursor_word", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = defaults })
vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled", "ModeChanged", "BufEnter" }, {
  group = group,
  callback = later,
})
vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "InsertEnter" }, {
  group = group,
  callback = function()
    timer:stop()
    clear()
  end,
})

return M

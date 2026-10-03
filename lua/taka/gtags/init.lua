-- Definitions, peeks, queries and indexes of a C tree from GNU Global, with
-- ctags where it has nothing: what the keys in lua/plugins/gtags.lua call.
-- The lookups are in lookup.lua, the peek window in peek.lua and the index
-- builds in index.lua.

local lookup = require("taka.gtags.lookup")
local jump_to_definition = lookup.jump

local function selected_text()
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return vim.trim(region[1] or "")
end

-- The file queries take the file name under the cursor, the rest the word.
local function under_cursor(kind)
  return vim.fn.expand((kind == "f" or kind == "i") and "<cfile>" or "<cword>")
end

-- Ctrl+click: move the cursor to what was clicked, then jump. Vim's built-in
-- <C-LeftMouse> runs `:tag <cword>` directly and bypasses any remap of <C-]>.
local function jump_at_mouse()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= 0 and pos.line > 0 then
    vim.api.nvim_set_current_win(pos.winid)
    vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.column - 1, 0) })
  end
  jump_to_definition(vim.fn.expand("<cword>"), "click")
end

local index = require("taka.gtags.index")

local M = {}

M.jump = jump_to_definition
M.peek = require("taka.gtags.peek").peek
M.query = lookup.query
M.selected_text = selected_text
M.under_cursor = under_cursor
M.jump_at_mouse = jump_at_mouse
M.build_gtags = index.build_gtags
M.update_gtags = index.update_gtags
M.build_ctags = index.build_ctags

-- The last jump, as :GtagsJumpDebug reports it: what started it, where the
-- answer came from and how long it took.
function M.jump_debug()
  local t = lookup.trace()
  if not t.started then
    return "(no jump yet)"
  end
  local function ms(at)
    return at and ("%.0f ms"):format((at - t.started) / 1e6) or "?"
  end
  return ("%s %s: from %s, answered in %s, landed in %s"):format(
    t.trigger,
    t.symbol,
    t.source or "(no answer yet)",
    ms(t.answered),
    ms(t.landed)
  )
end

M.peek_debug = require("taka.gtags.peek").debug

return M

-- The jump stack: the jumps to a definition or a reference the cursor is inside
-- now, one row a level, the deepest last, as a debugger lists its call stack
-- (<leader>jy). The rows are not indented by depth: the stack has no branches,
-- so the order says the depth, and nine levels down an indent took half the
-- panel and cut the function names short. It is Vim's tag stack, which <C-]>
-- and <C-t> already keep, and which the jumps of gtags (lua/taka/gtags/), of
-- ctags and of a language server's definitions and references all go onto; so
-- it is the same for any language.
--
-- Each row is where a jump was made from, named by the function it is in
-- (lua/taka/lib/enclosing.lua), and the last is where the last jump landed. A
-- level gone back from with <C-t> stays, dimmed, until the next jump drops it,
-- as the tag stack keeps it.
--
--   click, Enter     show that level, the stack kept; Enter also goes there
--   double click, <C-t>
--                    go back to that level, as <C-t> would a level at a time
--   m                pin the levels, each under the one before (pins.lua)
--   X                empty the stack
local M = {}

local sidebar = require("taka.lib.sidebar")
local enclosing = require("taka.lib.enclosing")

-- The panel, and the window whose stack it shows: the last window with a file
-- in it that was entered.
local panel = {} ---@type { picker: table?, win: integer? }

-- Where each jump landed, per window. The tag stack keeps where a jump started
-- and the name it went to, not the place it reached, so it is noted when the
-- stack grows, once the jump has moved the cursor.
local landings = {}
local seen = {}

local function key_of(item)
  return ("%s|%d|%d"):format(item.tagname, item.from[1], item.from[2])
end

local function signature(stack)
  local top = stack.items[#stack.items]
  return ("%d/%d/%s"):format(stack.curidx, stack.length, top and key_of(top) or "")
end

local function is_open()
  return panel.picker ~= nil and not panel.picker.closed
end

local function is_code_window(win)
  return vim.api.nvim_win_is_valid(win)
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    and vim.api.nvim_win_get_config(win).relative == ""
end

-- The levels of a window's stack: where each jump was made from, then where
-- the last one landed, if that is known.
function M.rows(win)
  local stack = vim.fn.gettagstack(win)
  local out = {}
  for index, item in ipairs(stack.items) do
    out[#out + 1] = { index = index, buf = item.from[1], lnum = item.from[2], tag = item.tagname }
  end
  local count = #stack.items
  local landing = landings[win] and landings[win][count]
  if count > 0 and landing and landing.key == key_of(stack.items[count]) then
    out[#out + 1] = { index = count + 1, buf = landing.buf, lnum = landing.lnum }
  end
  for _, row in ipairs(out) do
    row.current = row.index == stack.curidx
    row.returned = row.index > stack.curidx
    if vim.api.nvim_buf_is_valid(row.buf) then
      vim.fn.bufload(row.buf)
      row.file = vim.api.nvim_buf_get_name(row.buf)
      row.text = vim.trim(vim.api.nvim_buf_get_lines(row.buf, row.lnum - 1, row.lnum, false)[1] or "")
      row.name = enclosing.at(row.buf, row.lnum)
    end
  end
  return out, stack
end

local function row_text(row)
  local place = row.file and ("%s:%d"):format(vim.fs.basename(row.file), row.lnum) or ""
  return {
    { row.current and "● " or "  ", "DiagnosticInfo" },
    { row.name ~= "" and row.name or "(top level)", row.returned and "Comment" or "Function" },
    { row.tag and ("  → " .. row.tag) or "", "Comment" },
    {
      col = 0,
      virt_text = { { " " }, { place, "Comment" }, { " " } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    },
  }
end

local function refresh()
  if not is_open() then
    return
  end
  local current = panel.picker:current()
  local index = current and current.row.index
  sidebar.refresh(panel.picker, index, function(item)
    return item.row.index == index
  end)
end

-- A window's stack looked at again, after the cursor moved or a buffer or
-- window was entered: a jump is noted where it landed, and the panel drawn
-- again when the stack it shows has changed.
function M.track(win)
  win = win or vim.api.nvim_get_current_win()
  if not is_code_window(win) then
    return
  end
  local stack = vim.fn.gettagstack(win)
  local now = signature(stack)
  if now == seen[win] then
    return
  end
  seen[win] = now
  local top = stack.items[#stack.items]
  if top and stack.curidx == stack.length + 1 then
    landings[win] = landings[win] or {}
    local count = stack.length
    -- After the jump: the code that made it moves the cursor once it has put
    -- the jump on the stack.
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        landings[win][count] = {
          key = key_of(top),
          buf = vim.api.nvim_win_get_buf(win),
          lnum = vim.api.nvim_win_get_cursor(win)[1],
        }
        if win == panel.win then
          refresh()
        end
      end
    end)
  end
  if win == panel.win then
    refresh()
  end
end

-- A level shown in the window of the stack, which stays as it is. The cursor
-- goes there too with `go`, else it stays in the panel.
function M.visit(row, go)
  local win = panel.win
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(row.buf)) then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
  end)
  vim.api.nvim_win_set_buf(win, row.buf)
  vim.api.nvim_win_set_cursor(win, { row.lnum, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! ^zz")
  end)
  if go then
    vim.api.nvim_set_current_win(win)
  end
end

-- Back to a level, the levels above it kept for going forward, as :pop does,
-- and with the cursor in the window. A level ahead of where the stack is, one
-- gone back from, is only shown.
function M.back_to(row)
  local win = panel.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local stack = vim.fn.gettagstack(win)
  if row.index >= stack.curidx then
    return M.visit(row, true)
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd(("silent! %dpop"):format(stack.curidx - row.index))
  M.track(win)
end

function M.clear()
  local win = panel.win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.fn.settagstack(win, { items = {} }, "r")
    landings[win] = nil
    M.track(win)
    refresh()
  end
end

-- The levels pinned, each under the one before, with the function and the
-- name jumped to for a note.
function M.pin()
  local places = {}
  for _, row in ipairs(panel.win and M.rows(panel.win) or {}) do
    if row.file and row.file ~= "" then
      places[#places + 1] = {
        file = row.file,
        line = row.lnum,
        text = row.text,
        symbol = row.name,
        memo = (row.name ~= "" and row.name or "(top level)") .. (row.tag and (" → " .. row.tag) or ""),
      }
    end
  end
  local added = require("taka.pins").add_chain(places)
  vim.notify(("Pinned %d of %d levels (<leader>jo shows them)"):format(added, #places))
end

function M.toggle()
  if is_open() then
    return panel.picker:close()
  end
  local win = vim.api.nvim_get_current_win()
  panel.win = is_code_window(win) and win or panel.win or win
  local function current_row()
    local item = is_open() and panel.picker:current()
    return item and item.row
  end
  panel.picker = Snacks.picker({
    source = "jump_stack",
    title = "Jump Stack",
    finder = function()
      local items = {}
      for _, row in ipairs(M.rows(panel.win)) do
        items[#items + 1] =
          { text = (row.name or "") .. " " .. (row.tag or ""), row = row, sort = ("%06d"):format(row.index) }
      end
      return items
    end,
    format = function(item)
      return row_text(item.row)
    end,
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "sort" } },
    focus = "list",
    auto_close = false,
    jump = { close = false },
    layout = require("taka.lib.sidebar").layout(),
    on_close = function()
      panel.picker = nil
    end,
    confirm = function(_, item)
      if item then
        M.visit(item.row, true)
      end
    end,
    actions = {
      stack_back = function(_, item)
        if item then
          M.back_to(item.row)
        end
      end,
      stack_pin = function()
        M.pin()
      end,
      stack_clear = function()
        M.clear()
      end,
    },
    win = {
      list = {
        keys = {
          ["<2-LeftMouse>"] = "stack_back",
          ["<C-t>"] = "stack_back",
          ["m"] = "stack_pin",
          ["X"] = "stack_clear",
        },
      },
    },
  })
  -- A click shows the level clicked, the cursor staying in the panel; the
  -- click goes through first, so that the row it lands on is the current one.
  local list = panel.picker.list.win
  vim.keymap.set("n", "<LeftMouse>", function()
    if vim.fn.getmousepos().winid == list.win then
      vim.schedule(function()
        local row = current_row()
        if row then
          M.visit(row)
        end
      end)
    end
    return "<LeftMouse>"
  end, { buffer = list.buf, expr = true, desc = "Show the level clicked" })
end

-- For the checks: the rows of the panel as text.
function M.lines()
  if not is_open() then
    return {}
  end
  local out = {}
  for _, row in ipairs(M.rows(panel.win)) do
    local parts = {}
    for _, part in ipairs(row_text(row)) do
      if part[1] then
        parts[#parts + 1] = part[1]
      elseif part.virt_text then
        parts[#parts + 1] = "  @" .. part.virt_text[2][1]
      end
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

local group = vim.api.nvim_create_augroup("config_jump_stack", { clear = true })
vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
  group = group,
  callback = function()
    M.track()
  end,
})
-- The panel follows the window last worked in.
vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if is_code_window(win) then
      M.track(win)
      if is_open() and panel.win ~= win then
        panel.win = win
        refresh()
      end
    end
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(event)
    local win = tonumber(event.match)
    landings[win], seen[win] = nil, nil
  end,
})

return M

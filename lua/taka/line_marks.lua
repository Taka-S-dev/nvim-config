-- Lines marked by hand, their background tinted, as a word is lit with
-- <leader>hh (lua/taka/words.lua): a place to come back to while reading,
-- such as the line a jump left from, marked in one key and with no note.
--
--   <leader>hl  mark the cursor's line, or the lines selected; on a marked
--               line, take its mark off
--   <leader>hj  next marked line       <leader>hk  previous
--   <leader>hL  take every mark off in the buffer
--
-- A mark moves with its line as the buffer is edited, and lasts while the
-- buffer is loaded. A pin (<leader>jm, lua/taka/pins/) is what is kept, with
-- a note, across restarts.
local M = {}

local bit = require("bit")

local ns = vim.api.nvim_create_namespace("config_line_marks")

-- A channel of a colour as #rrggbb, `amount` of `top` over `under`.
local function blend(top, under, amount)
  local out = 0
  for shift = 16, 0, -8 do
    local a, b = bit.band(bit.rshift(top, shift), 0xff), bit.band(bit.rshift(under, shift), 0xff)
    out = out + bit.lshift(math.floor(a * amount + b * (1 - amount) + 0.5), shift)
  end
  return out
end

-- The line in a quarter of the yellow of the first lit word over the
-- background, so its text reads as it did; its number in the full yellow.
local function colours()
  local yellow = 0xffc777
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0x222436
  vim.api.nvim_set_hl(0, "LineMark", { bg = blend(yellow, normal, 0.25), default = true })
  vim.api.nvim_set_hl(0, "LineMarkNr", { fg = yellow, bold = true, default = true })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_line_marks", { clear = true }),
  callback = colours,
})

-- The marks of `buf` from row `first` to `last` (0-based, both in).
local function marks(buf, first, last)
  return vim.api.nvim_buf_get_extmarks(buf, ns, { first, 0 }, { last, -1 }, {})
end

-- The rows of the buffer that are marked, in order (0-based).
function M.rows(buf)
  local out = {}
  for _, mark in ipairs(marks(buf or 0, 0, -1)) do
    out[#out + 1] = mark[2]
  end
  return out
end

local function mark(buf, row)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    line_hl_group = "LineMark",
    number_hl_group = "LineMarkNr",
    -- Under what the editor lights itself, the cursor's line and a search.
    priority = 5,
  })
end

-- <leader>hl: the cursor's line, or in Visual mode the lines selected,
-- marked; taken off instead when every one of them is marked already.
function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = vim.fn.line("."), vim.fn.line(".")
  if vim.fn.mode():match("^[vV\22]") then
    first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  local marked = {}
  for _, found in ipairs(marks(buf, first - 1, last - 1)) do
    marked[found[2]] = found[1]
  end
  local all = true
  for row = first - 1, last - 1 do
    all = all and marked[row] ~= nil
  end
  for row = first - 1, last - 1 do
    if all then
      vim.api.nvim_buf_del_extmark(buf, ns, marked[row])
    elseif not marked[row] then
      mark(buf, row)
    end
  end
  require("taka.overview").soon()
end

-- <leader>hj and <leader>hk: the next marked line below the cursor, or with
-- `back` above it, going round past the end.
function M.jump(back)
  local rows = M.rows(0)
  if #rows == 0 then
    return vim.notify("No lines are marked (<leader>hl marks one)")
  end
  local here = vim.fn.line(".") - 1
  local target
  if back then
    for index = #rows, 1, -1 do
      if rows[index] < here then
        target = rows[index]
        break
      end
    end
    target = target or rows[#rows]
  else
    for _, row in ipairs(rows) do
      if row > here then
        target = row
        break
      end
    end
    target = target or rows[1]
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
  vim.cmd("normal! ^")
end

-- <leader>hL: every mark of the buffer taken off.
function M.clear()
  vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
  require("taka.overview").soon()
end

return M

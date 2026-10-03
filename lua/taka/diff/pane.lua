-- The change under the cursor in a diff, as each side has it, in a pane along
-- the bottom split as WinMerge's diff pane is: the left side above, the right
-- side below, each under its own heading, and the two scrolled together. The
-- whole block of changed lines the cursor is in is shown, or the cursor's line
-- alone where nothing changed. Both halves wrap, so a change at the far end of
-- a long line is in sight without scrolling sideways, and within each line the
-- part that differs is marked as in the diff.
--
-- It opens by itself in a tab with two windows in diff mode and goes when the
-- diff does; <leader>uP closes it and brings it back, and q in it ends the
-- whole comparison, as it does anywhere in one (lua/taka/diff/quit.lua).
-- Lines are paired through the rows of the aligned diff
-- (lua/taka/diff/scroll.lua): a line only one side has faces a blank line
-- on the other, so the halves stay row for row.
local M = {}

local ns = vim.api.nvim_create_namespace("config_diff_pane")
local panes = {} ---@type table<integer, { parts: { win: integer, buf: integer }[], key: string? }>
-- The longest block shown, in rows of the diff, and the share of the screen
-- the pane takes, both halves together; a longer block scrolls inside it.
local MAX_ROWS = 60
local SHARE = 0.3

-- The pane's height, both halves together, as last set by hand (a border
-- dragged, or <C-w>+ / <C-w>-), kept for the next pane; until then, the
-- share above.
local chosen ---@type integer?

-- The halves given the pane's rows between them evenly, the bottom one the
-- odd row. The top half is let go of its fixed height for it, so that the
-- rows the bottom one takes or gives come from the top one and not from the
-- diff above.
local function balance(pane, total)
  local top, bottom = pane.parts[1].win, pane.parts[2].win
  if not (vim.api.nvim_win_is_valid(top) and vim.api.nvim_win_is_valid(bottom)) then
    return
  end
  local half = math.floor(total / 2)
  if vim.api.nvim_win_get_height(top) == half and vim.api.nvim_win_get_height(bottom) == total - half then
    return
  end
  vim.wo[top].winfixheight = false
  vim.api.nvim_win_set_height(bottom, total - half)
  vim.api.nvim_win_set_height(top, half)
  vim.wo[top].winfixheight = true
end

-- The pane as tall as it was last made by hand, or as its share of the
-- screen, whatever block it holds: the pane never sizes itself to the block.
-- One that grew and shrank with the block under the cursor resized the diff
-- above it at every block the wheel went past, which moved the view and the
-- cursor, which moved to another block: the diff went on shaking after the
-- wheel had stopped.
local function size(pane)
  local total = chosen or 2 * math.max(3, math.floor(vim.o.lines * SHARE / 2))
  local top, bottom = pane.parts[1].win, pane.parts[2].win
  if vim.api.nvim_win_is_valid(top) and vim.api.nvim_win_is_valid(bottom) then
    vim.api.nvim_win_set_height(top, math.floor(total / 2))
    vim.api.nvim_win_set_height(bottom, total - math.floor(total / 2))
  end
end

-- A half resized, by hand or by the layout: the pane's height is the one to
-- keep, shared out between the halves evenly again.
function M.resized(wins)
  for _, pane in pairs(panes) do
    for _, part in ipairs(pane.parts) do
      if vim.tbl_contains(wins, part.win) and vim.api.nvim_win_is_valid(part.win) then
        chosen = vim.api.nvim_win_get_height(pane.parts[1].win) + vim.api.nvim_win_get_height(pane.parts[2].win)
        balance(pane, chosen)
        return
      end
    end
  end
end

M.enabled = true

-- The windows of the diff in a tab, left to right.
local function diff_windows(tab)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" and vim.wo[win].diff then
      wins[#wins + 1] = win
    end
  end
  table.sort(wins, function(a, b)
    return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
  end)
  return wins
end

local function close(tab)
  local pane = panes[tab]
  panes[tab] = nil
  for _, part in ipairs(pane and pane.parts or {}) do
    if vim.api.nvim_win_is_valid(part.win) then
      pcall(vim.api.nvim_win_close, part.win, true)
    end
  end
end

-- One side's view of the rows of the diff: the line on a row, or nil where
-- the row is a filler line, the line being only on the other side.
local function side_of(win)
  local scroll = require("taka.diff.scroll")
  local rows = scroll.rows_of(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local side = { rows = rows, win = win }
  function side.line(row)
    local line = scroll.line_on(rows, row)
    if rows[line] == row then
      return line
    end
  end
  function side.text(row)
    local line = side.line(row)
    return line and vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
  end
  function side.changed(row)
    local line = side.line(row)
    if not line then
      return true
    end
    return vim.api.nvim_win_call(win, function()
      return vim.fn.diff_hlID(line, 1) ~= 0
    end)
  end
  return side
end

-- Where two lines part: what is the same at the start, and at the end after
-- that, counted in whole characters so that a multibyte one is not split. The
-- byte ranges of each line that differ.
local function differing(a, b)
  local chars_a, chars_b = vim.fn.split(a, [[\zs]]), vim.fn.split(b, [[\zs]])
  local head = 0
  while head < #chars_a and head < #chars_b and chars_a[head + 1] == chars_b[head + 1] do
    head = head + 1
  end
  local tail = 0
  while tail < #chars_a - head and tail < #chars_b - head and chars_a[#chars_a - tail] == chars_b[#chars_b - tail] do
    tail = tail + 1
  end
  -- Out to whole words, as WinMerge marks them: `checksum` against `crc32`
  -- shares its first letter, and marking from the second reads as noise.
  local function word(char)
    return char ~= nil and char:match("^[%w_]$") ~= nil
  end
  while head > 0 and word(chars_a[head]) and (word(chars_a[head + 1]) or word(chars_b[head + 1])) do
    head = head - 1
  end
  while
    tail > 0
    and word(chars_a[#chars_a - tail + 1])
    and (word(chars_a[#chars_a - tail]) or word(chars_b[#chars_b - tail]))
  do
    tail = tail - 1
  end
  local function span(chars)
    return { #table.concat(chars, "", 1, head), #table.concat(chars, "", 1, #chars - tail) }
  end
  return { span(chars_a), span(chars_b) }
end

-- A line cut into words, runs of blanks and single other characters, each
-- with the byte range it takes.
local function tokens(line)
  local out, at = {}, 1
  while at <= #line do
    local from, to = line:find("^[%w_]+", at)
    if not from then
      from, to = line:find("^%s+", at)
    end
    if not from then
      -- One character, whole: a multibyte one is its first byte and the
      -- continuation bytes after it.
      from, to = line:find("^[%z\1-\127\194-\244][\128-\191]*", at)
    end
    out[#out + 1] = { text = line:sub(from, to), from = from - 1, to = to }
    at = to + 1
  end
  return out
end

-- The parts of two lines that differ, word by word, as WinMerge marks them:
-- the words the lines share in order are left alone and every other run is
-- marked, so two changes in one line are two marks and what lies between
-- them is not. Byte ranges for each line, blanks trimmed from their ends. A
-- pair too long to compare this way is marked from where the lines part to
-- where they meet again.
local WORD_PAIRS = 250000
local function marks(a, b)
  local ta, tb = tokens(a), tokens(b)
  if #ta * #tb > WORD_PAIRS then
    local spans = differing(a, b)
    return { { spans[1] }, { spans[2] } }
  end
  -- The longest run of words the two share, in order.
  local length = {}
  for i = #ta + 1, 1, -1 do
    length[i] = {}
    for j = #tb + 1, 1, -1 do
      if i > #ta or j > #tb then
        length[i][j] = 0
      elseif ta[i].text == tb[j].text then
        length[i][j] = length[i + 1][j + 1] + 1
      else
        length[i][j] = math.max(length[i + 1][j], length[i][j + 1])
      end
    end
  end
  local kept_a, kept_b = {}, {}
  local i, j = 1, 1
  while i <= #ta and j <= #tb do
    if ta[i].text == tb[j].text then
      kept_a[i], kept_b[j] = true, true
      i, j = i + 1, j + 1
    elseif length[i + 1][j] >= length[i][j + 1] then
      i = i + 1
    else
      j = j + 1
    end
  end
  local function spans(list, kept)
    local out, open = {}, nil
    for index, token in ipairs(list) do
      local blank = token.text:match("^%s+$") ~= nil
      if not kept[index] and not blank then
        if open then
          open[2] = token.to
        else
          open = { token.from, token.to }
          out[#out + 1] = open
        end
      elseif kept[index] then
        open = nil
      end
    end
    return out
  end
  return { spans(ta, kept_a), spans(tb, kept_b) }
end

local function label(win)
  local name = vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
  return name ~= "" and name or "[No Name]"
end

-- The rows of the block the cursor's row is in: the changed rows around it,
-- or the row alone where it did not change.
local function block(left, right, row)
  local function changed(at)
    return left.changed(at) or right.changed(at)
  end
  if not changed(row) then
    return row, row
  end
  local first, last = row, row
  while first > 1 and changed(first - 1) and last - first < MAX_ROWS do
    first = first - 1
  end
  local total = math.max(left.rows[#left.rows] or 0, right.rows[#right.rows] or 0)
  while last < total and changed(last + 1) and last - first < MAX_ROWS do
    last = last + 1
  end
  return first, last
end

-- The two windows of the pane, top for the left side and bottom for the right.
local function open(tab)
  local parts = {}
  for index = 1, 2 do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "diffpane"
    local at = index == 1 and { split = "below", win = -1, height = 3 }
      or { split = "below", win = parts[1].win, height = 3 }
    local win = vim.api.nvim_open_win(buf, false, at)
    for option, value in pairs({
      wrap = true,
      -- Whole lines at a time: the halves are kept row for row, and a half
      -- stopped part way down a wrapped line was pulled back to its start
      -- by the other, and pulled the other in turn.
      smoothscroll = false,
      -- No lines kept clear around the cursor: in a half a few rows high,
      -- holding wrapped lines, keeping them clear pushed the view against the
      -- wheel, down while it turned up.
      scrolloff = 0,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      statuscolumn = "",
      list = false,
      cursorline = false,
      winfixheight = true,
    }) do
      vim.wo[win][option] = value
    end
    parts[index] = { win = win, buf = buf }
  end
  local pane = { parts = parts }
  panes[tab] = pane
  return pane
end

local function is_open(pane)
  return pane ~= nil and vim.api.nvim_win_is_valid(pane.parts[1].win) and vim.api.nvim_win_is_valid(pane.parts[2].win)
end

-- The other half of the pane brought to the line `win` shows at its top.
-- Both hold one line per row of the block, so the same line number is the
-- same row on either side.
function M.follow(win)
  for _, pane in pairs(panes) do
    if is_open(pane) then
      for index, part in ipairs(pane.parts) do
        if part.win == win then
          local other = pane.parts[3 - index].win
          local top = vim.fn.line("w0", win)
          if vim.fn.line("w0", other) ~= top then
            pcall(vim.api.nvim_win_call, other, function()
              vim.fn.winrestview({ topline = top, lnum = top })
            end)
          end
          return
        end
      end
    end
  end
end

-- After a scroll, the half that leads: the one under the mouse, which is the
-- one the wheel turns, or else the one the cursor is in. Only the other half
-- is moved. Following whichever half reported a scroll, the half moved to
-- follow reported one of its own, sometimes with the wheel's next turn already
-- in it, and pulled the first back: the halves went up and down past the
-- wheel stopping.
function M.scrolled(wins)
  local mouse = vim.fn.getmousepos().winid
  local current = vim.api.nvim_get_current_win()
  for _, pane in pairs(panes) do
    if is_open(pane) then
      local touched, lead = false, nil
      for _, part in ipairs(pane.parts) do
        touched = touched or vim.tbl_contains(wins, part.win)
        if part.win == mouse then
          lead = part.win
        end
      end
      if touched then
        for _, part in ipairs(pane.parts) do
          if not lead and part.win == current then
            lead = part.win
          end
        end
        if lead then
          M.follow(lead)
        end
      end
    end
  end
end

-- The pane of the current tab brought up to date with the cursor, in the diff
-- window the cursor is in or else the leftmost one.
function M.refresh()
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = diff_windows(tab)
  if not M.enabled or vim.t.diff_pane_closed or #wins ~= 2 then
    return close(tab)
  end
  local current = vim.api.nvim_get_current_win()
  local from = vim.tbl_contains(wins, current) and current or wins[1]
  local cursor = vim.api.nvim_win_get_cursor(from)[1]
  local row = require("taka.diff.scroll").rows_of(from)[cursor]
  if not row then
    return
  end
  local left, right = side_of(wins[1]), side_of(wins[2])
  -- Lines only the other side has leave filler above the next line on this
  -- one, and ]c stops on that next line, a filler being no place for the
  -- cursor. The block is the one just above, then.
  local mine = from == wins[1] and left or right
  if row > 1 and not left.changed(row) and not right.changed(row) and not mine.line(row - 1) then
    row = row - 1
  end
  local first, last = block(left, right, row)

  -- The same block as shown already is left as it is, scrolled where it was:
  -- scrolling the pane itself comes back here, and redrawing it would put it
  -- back at the top.
  local key = table.concat({
    wins[1],
    wins[2],
    first,
    last,
    vim.b[vim.api.nvim_win_get_buf(wins[1])].changedtick,
    vim.b[vim.api.nvim_win_get_buf(wins[2])].changedtick,
  }, ":")
  local pane = panes[tab]
  if is_open(pane) and pane.key == key then
    return
  end
  local opened = not is_open(pane)
  if opened then
    close(tab)
    pane = open(tab)
  end
  pane.key = key

  -- One line per row of the block on both sides, a line only the other side
  -- has standing as a blank one here, so that the two stay row for row.
  local texts = { {}, {} }
  for at = first, last do
    texts[1][#texts[1] + 1] = left.text(at) or false
    texts[2][#texts[2] + 1] = right.text(at) or false
  end
  for index, part in ipairs(pane.parts) do
    local mine_texts, theirs = texts[index], texts[3 - index]
    local lines = {}
    for offset, text in ipairs(mine_texts) do
      lines[offset] = text or ""
    end
    vim.bo[part.buf].modifiable = true
    vim.api.nvim_buf_set_lines(part.buf, 0, -1, false, lines)
    vim.bo[part.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(part.buf, ns, 0, -1)
    vim.wo[part.win].winbar = "%#Title# " .. label(wins[index]):gsub("%%", "%%%%") .. "%*"
    -- A whole line's colour, as a range through its end rather than a line
    -- highlight: a line highlight is laid over everything drawn on the line,
    -- whatever its priority, and hid the words marked within it.
    local function paint(line, group)
      vim.api.nvim_buf_set_extmark(part.buf, ns, line, 0, {
        end_row = line + 1,
        end_col = 0,
        hl_group = group,
        hl_eol = true,
        priority = 100,
        strict = false,
      })
    end
    for offset, text in ipairs(mine_texts) do
      local line, other = offset - 1, theirs[offset]
      if not text then
        vim.api.nvim_buf_set_extmark(part.buf, ns, line, 0, {
          virt_text = { { "(no line on this side)", "Comment" } },
          virt_text_pos = "inline",
        })
        paint(line, "DiffDelete")
      elseif not other then
        paint(line, "DiffAdd")
      elseif other ~= text then
        paint(line, "DiffChange")
        for _, span in ipairs(marks(text, other)[1]) do
          if span[2] > span[1] then
            vim.api.nvim_buf_set_extmark(
              part.buf,
              ns,
              line,
              span[1],
              { end_col = span[2], hl_group = "DiffText", priority = 200 }
            )
          end
        end
      end
    end
    vim.api.nvim_win_set_cursor(part.win, { 1, 0 })
  end

  if not opened then
    return
  end
  size(pane)
  -- The pane takes its rows from the diff when it opens, and a side cut
  -- shorter under a cursor near its foot kept its top line: the change the
  -- cursor was on went out of sight, and entering the window pulled the
  -- cursor up to what was left. A side whose cursor is out of view is centred
  -- on it instead; only then, the pane's height being fixed after.
  for _, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      local margin = vim.wo.scrolloff >= 0 and vim.wo.scrolloff or vim.o.scrolloff
      local bottom = view.topline + vim.api.nvim_win_get_height(0) - 1 - margin
      if view.lnum < view.topline or view.lnum > bottom then
        vim.cmd("normal! zz")
      end
    end)
  end
end

-- For the checks: each half's lines, the parts of each marked as differing,
-- and "(none)" for a line only the other side has.
function M.shown()
  local pane = panes[vim.api.nvim_get_current_tabpage()]
  if not is_open(pane) then
    return nil
  end
  local shown = {}
  for index, part in ipairs(pane.parts) do
    local out = {}
    for at, line in ipairs(vim.api.nvim_buf_get_lines(part.buf, 0, -1, false)) do
      local marked, missing = {}, false
      for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(part.buf, ns, { at - 1, 0 }, { at - 1, -1 }, { details = true }))
      do
        if mark[4].hl_group == "DiffText" then
          marked[#marked + 1] = line:sub(mark[3] + 1, mark[4].end_col)
        end
        if mark[4].virt_text then
          missing = true
        end
      end
      out[#out + 1] = missing and "(none)" or (line .. (#marked > 0 and " [" .. table.concat(marked, ",") .. "]" or ""))
    end
    shown[index] = table.concat(out, " / ")
  end
  shown.windows = { pane.parts[1].win, pane.parts[2].win }
  return shown
end

Snacks.toggle({
  name = "Diff pane",
  get = function()
    return M.enabled and not vim.t.diff_pane_closed
  end,
  set = function(state)
    M.enabled = state
    vim.t.diff_pane_closed = nil
    if state then
      M.refresh()
    else
      for tab in pairs(panes) do
        close(tab)
      end
    end
  end,
}):map("<leader>uP")

local group = vim.api.nvim_create_augroup("config_diff_pane", { clear = true })
vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "DiffUpdated", "BufWinEnter", "TabEnter" }, {
  group = group,
  callback = function()
    vim.schedule(M.refresh)
  end,
})
vim.api.nvim_create_autocmd("WinScrolled", {
  group = group,
  callback = function()
    -- v:event has an entry for each window that scrolled, keyed by its id.
    local wins = {}
    for id in pairs(vim.v.event) do
      wins[#wins + 1] = tonumber(id)
    end
    M.scrolled(wins)
    vim.schedule(M.refresh)
  end,
})
vim.api.nvim_create_autocmd("WinResized", {
  group = group,
  callback = function()
    M.resized(vim.v.event.windows or {})
  end,
})
vim.api.nvim_create_autocmd("VimResized", {
  group = group,
  callback = function()
    for _, pane in pairs(panes) do
      size(pane)
    end
  end,
})
vim.api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = "diff",
  callback = function()
    vim.schedule(M.refresh)
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(event)
    local closed = tonumber(event.match)
    for tab, pane in pairs(panes) do
      if pane.parts[1].win == closed or pane.parts[2].win == closed then
        -- Closed by hand: the other half goes too, and the pane stays closed
        -- in this tab until <leader>uP.
        close(tab)
        pcall(function()
          vim.t[tab].diff_pane_closed = true
        end)
      end
    end
    vim.schedule(M.refresh)
  end,
})

return M

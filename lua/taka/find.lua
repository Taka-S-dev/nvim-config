-- A bar to find text in the file shown, by the mouse as much as by keys
-- (<leader>sf): a box at the top right of the window that stays open while the
-- code is read, its matches lit and counted, and buttons to go to the next or
-- the previous one or to close it. / does the same from the command line, but
-- moves the view as it is typed and is gone once Enter is pressed, and the
-- place being read was easily lost.
--
-- The text is found as it is typed, `.` and `*` and all; in lower case it
-- matches either case, with a capital it matches the case typed, as / does
-- here ('smartcase'). Closed, the search is kept, and n and N go on with it.
local M = {}

local namespace = vim.api.nvim_create_namespace("config_find")

-- The bar open: its window and buffer, the window it finds in, and where the
-- search starts from, the cursor's place when the bar opened or the match last
-- gone to.
-- The file's buffer and whether it scrolled smoothly before, to give back.
local bar = {} ---@type { win: integer?, buf: integer?, code: integer?, from: integer[]?, code_buf: integer?, smooth: boolean? }

-- How the text is matched, kept from one bar to the next, as an editor's find
-- keeps them: `case`, the case typed always, where in lower case either case
-- matches; `word`, whole words only, so `len` finds no `strlen`. Patterns are
-- left to /.
M.options = { case = false, word = false }

-- The buttons at the right of the bar, in the order they stand: the two ways
-- of matching, lit while on, then cod-arrow-up, cod-arrow-down and cod-close
-- of the Nerd Font.
local BUTTONS = {
  { text = " Aa ", action = "case", toggle = "case" },
  { text = " ab ", action = "word", toggle = "word" },
  { text = " \u{eaa1} ", action = "previous" },
  { text = " \u{ea9a} ", action = "next" },
  { text = " \u{ea76} ", action = "close" },
}

local function colours()
  vim.api.nvim_set_hl(0, "FindButton", { link = "Special", default = true })
  local special = vim.api.nvim_get_hl(0, { name = "Special", link = false }).fg
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  vim.api.nvim_set_hl(0, "FindToggleOn", { fg = normal, bg = special, bold = true, default = true })
  vim.api.nvim_set_hl(0, "FindCount", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "FindNone", { link = "DiagnosticWarn", default = true })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_find_colours", { clear = true }),
  callback = colours,
})

local function is_open()
  return bar.win ~= nil and vim.api.nvim_win_is_valid(bar.win)
end

-- The pattern the text in the bar is found by: the text as it is, the case
-- going by whether it has a capital unless the case is always matched, and
-- whole words only when asked.
function M.pattern(text)
  local case = (M.options.case or text:find("%u")) and "\\C" or "\\c"
  local escaped = text:gsub("\\", "\\\\")
  if M.options.word then
    escaped = "\\<" .. escaped .. "\\>"
  end
  return "\\V" .. case .. escaped
end

local function query()
  return is_open() and (vim.api.nvim_buf_get_lines(bar.buf, 0, 1, false)[1] or "") or ""
end

-- The count and the buttons drawn at the right of the bar.
local function draw(count)
  vim.api.nvim_buf_clear_namespace(bar.buf, namespace, 0, -1)
  local chunks = { { count.text, count.none and "FindNone" or "FindCount" }, { " " } }
  for _, button in ipairs(BUTTONS) do
    local on = button.toggle and M.options[button.toggle]
    chunks[#chunks + 1] = { button.text, on and "FindToggleOn" or "FindButton" }
  end
  vim.api.nvim_buf_set_extmark(bar.buf, namespace, 0, 0, { virt_text = chunks, virt_text_pos = "right_align" })
end

-- Which match the cursor in the code is on, of how many.
local function count()
  local text = query()
  if text == "" then
    return { text = "" }
  end
  local found = vim.api.nvim_win_call(bar.code, function()
    return vim.fn.searchcount({ pattern = M.pattern(text), maxcount = 9999, timeout = 200, recompute = true })
  end)
  if not found.total or found.total == 0 then
    return { text = "no matches", none = true }
  end
  return { text = ("%d/%d"):format(found.current, found.total) }
end

-- The search set to the text in the bar, its matches lit and the cursor in the
-- code on the first one from where the search starts, or nothing lit for an
-- empty bar.
-- The matches are lit or put out once the change of the text is handled: what
-- is set while an autocommand runs is set back when it ends, as :nohlsearch
-- is, and the bar emptied still lit the last letter typed.
local function light(on)
  vim.schedule(function()
    vim.v.hlsearch = on and 1 or 0
  end)
end

function M.update()
  if not is_open() or not vim.api.nvim_win_is_valid(bar.code) then
    return
  end
  local text = query()
  if text == "" then
    light(false)
    return draw({ text = "" })
  end
  local pattern = M.pattern(text)
  vim.fn.setreg("/", pattern)
  light(true)
  vim.api.nvim_win_call(bar.code, function()
    vim.api.nvim_win_set_cursor(bar.code, bar.from)
    vim.fn.search(pattern, "c")
  end)
  draw(count())
end

-- The next match, or the previous one with a negative `direction`, the bar
-- keeping the cursor.
function M.go(direction)
  local text = query()
  if text == "" or not vim.api.nvim_win_is_valid(bar.code) then
    return
  end
  local pattern = M.pattern(text)
  vim.fn.setreg("/", pattern)
  vim.v.hlsearch = 1
  vim.api.nvim_win_call(bar.code, function()
    vim.fn.search(pattern, direction < 0 and "b" or "")
    vim.cmd("normal! zv")
    bar.from = vim.api.nvim_win_get_cursor(bar.code)
  end)
  draw(count())
end

function M.close()
  local code = bar.code
  if bar.code_buf and vim.api.nvim_buf_is_valid(bar.code_buf) then
    vim.b[bar.code_buf].snacks_scroll = bar.smooth
  end
  if is_open() then
    vim.api.nvim_win_close(bar.win, true)
  end
  bar = {}
  vim.v.hlsearch = 0
  if code and vim.api.nvim_win_is_valid(code) then
    vim.api.nvim_set_current_win(code)
  end
end

-- What the button under the column `col` of the bar (1-based) does, or nil.
function M.button_at(col)
  local width = vim.api.nvim_win_get_width(bar.win)
  local right = width
  for index = #BUTTONS, 1, -1 do
    local cells = vim.fn.strdisplaywidth(BUTTONS[index].text)
    if col > right - cells and col <= right then
      return BUTTONS[index].action
    end
    right = right - cells
  end
end

local function press(action)
  if action == "close" then
    M.close()
  elseif action == "next" then
    M.go(1)
  elseif action == "previous" then
    M.go(-1)
  elseif action == "case" or action == "word" then
    M.options[action] = not M.options[action]
    M.update()
  end
end

-- What a click on the bar does: on a button it presses it, the text left to
-- be typed on after next or previous, as in the box of an editor's find; on
-- the text it puts the cursor there to type.
local function click_on_bar(mouse)
  local action = M.button_at(mouse.wincol)
  if action then
    press(action)
    if action ~= "close" and is_open() then
      vim.api.nvim_set_current_win(bar.win)
      vim.cmd("startinsert!")
    end
    return
  end
  vim.api.nvim_set_current_win(bar.win)
  local line = vim.api.nvim_buf_get_lines(bar.buf, 0, 1, false)[1] or ""
  vim.api.nvim_win_set_cursor(bar.win, { 1, math.min(math.max(mouse.column - 1, 0), #line) })
  vim.cmd("startinsert")
end

local function keys(buf)
  local function set(lhs, fn, desc)
    vim.keymap.set({ "n", "i" }, lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  set("<CR>", function()
    M.go(1)
  end, "Next match")
  set("<S-CR>", function()
    M.go(-1)
  end, "Previous match")
  set("<Down>", function()
    M.go(1)
  end, "Next match")
  set("<Up>", function()
    M.go(-1)
  end, "Previous match")
  set("<Esc>", M.close, "Close the find bar")
  set("<C-c>", M.close, "Close the find bar")
  -- The keys of an editor's find for the two ways of matching.
  set("<A-c>", function()
    press("case")
  end, "Match the case typed, or not")
  set("<A-w>", function()
    press("word")
  end, "Whole words only, or not")
  -- A click while the cursor is in the bar, single or one of quick ones: each
  -- is one press. Clicks made quickly one after another come as a double,
  -- triple or quadruple click, which selected the word under the arrow and
  -- left the keys after to that selection, so most of a run of clicks did
  -- nothing. A click outside the bar goes where it was made.
  for _, lhs in ipairs({ "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    vim.keymap.set({ "n", "i", "x", "s" }, lhs, function()
      local mouse = vim.fn.getmousepos()
      if mouse.winid == bar.win then
        return click_on_bar(mouse)
      end
      if mouse.winid ~= 0 then
        vim.cmd("stopinsert")
        vim.api.nvim_set_current_win(mouse.winid)
        if mouse.line > 0 then
          vim.api.nvim_win_set_cursor(mouse.winid, { mouse.line, math.max(mouse.column - 1, 0) })
        end
      end
    end, { buffer = buf, desc = "Press a button, or type" })
  end
end

-- The bar opened over the current window, or the one open there entered to
-- type in. It starts with the text selected, else with the last text looked
-- for, ready to be typed over.
function M.open()
  local selected
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    selected = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })[1]
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  if is_open() then
    vim.api.nvim_set_current_win(bar.win)
    if selected then
      vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, { selected })
      M.update()
    end
    return vim.cmd("startinsert!")
  end
  local code = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  -- No completion in the bar: its menu took Enter, meant for the next match.
  vim.b[buf].completion = false
  local text = selected or M.last or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local width = math.max(math.min(56, vim.api.nvim_win_get_width(code) - 4), 30)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = code,
    anchor = "NE",
    row = 0,
    col = vim.api.nvim_win_get_width(code),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " Find ",
    title_pos = "left",
    zindex = 60,
  })
  bar = { win = win, buf = buf, code = code, from = vim.api.nvim_win_get_cursor(code) }
  -- No smooth scrolling in the file while the bar is open: it carried the
  -- cursor to a match a line at a time, and an arrow clicked again meanwhile
  -- went on from a line on the way and stopped on the same match again.
  bar.code_buf = vim.api.nvim_win_get_buf(code)
  bar.smooth = vim.b[bar.code_buf].snacks_scroll
  vim.b[bar.code_buf].snacks_scroll = false
  keys(buf)
  local group = vim.api.nvim_create_augroup("config_find_bar", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.last = query()
      M.update()
    end,
  })
  -- The count follows n and N, or a click, in the code while the bar is open.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      if is_open() and vim.api.nvim_get_current_win() == bar.code then
        draw(count())
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if tonumber(event.match) == bar.code or tonumber(event.match) == bar.win then
        vim.schedule(function()
          if is_open() and not vim.api.nvim_win_is_valid(bar.code or -1) then
            vim.api.nvim_win_close(bar.win, true)
          end
          if not is_open() then
            if bar.code_buf and vim.api.nvim_buf_is_valid(bar.code_buf) then
              vim.b[bar.code_buf].snacks_scroll = bar.smooth
            end
            bar = {}
            pcall(vim.api.nvim_del_augroup_by_name, "config_find_bar")
          end
        end)
      end
    end,
  })
  M.update()
  vim.cmd("startinsert!")
end

-- A click on the bar while the cursor is in another window: a mapping in the
-- bar is not seen from there, and the click went into the bar and did nothing
-- more. Clicks are watched for this, not mapped; by the time this runs,
-- Neovim has put the cursor in the bar, and the next quick clicks go to the
-- bar's own mappings. The key as pressed is looked at, not what a mapping
-- made of it.
local left_mouse = vim.keycode("<LeftMouse>")
vim.on_key(function(key, typed)
  if (typed ~= "" and typed or key) ~= left_mouse or not is_open() then
    return
  end
  if vim.api.nvim_get_current_win() == bar.win then
    return
  end
  vim.schedule(function()
    local mouse = vim.fn.getmousepos()
    if is_open() and mouse.winid == bar.win then
      click_on_bar(mouse)
    end
  end)
end, namespace)

-- For the checks: the count and the buttons as the bar shows them.
function M.shown()
  if not is_open() then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmarks(bar.buf, namespace, 0, -1, { details = true })[1]
  local parts = {}
  for _, chunk in ipairs(mark and mark[4].virt_text or {}) do
    parts[#parts + 1] = chunk[1]
  end
  return { text = query(), right = table.concat(parts), win = bar.win, code = bar.code }
end

return M

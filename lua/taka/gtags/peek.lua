-- Read a definition without leaving the current position: a window opens clear
-- of the line being read, with the code around the definition, and the file
-- being read stays on screen around it. q or Esc closes it, Enter jumps there
-- after all. Nothing is pushed on the tag stack until something actually moves.

local lookup = require("taka.gtags.lookup")
local show, ctags_definitions = lookup.show, lookup.ctags_definitions
local lookup_definition, jump_to_definition = lookup.lookup_definition, lookup.jump

local peek_window
local peek_debug = "(no window opened yet)"
local peek_marks = vim.api.nvim_create_namespace("gtags_peek")
local peek_definition -- defined below; the keys inside the window call it
-- The peeks left behind by jumping from inside one, newest last, so <C-t> in
-- the window can walk back through them the way it does through real jumps.
local peek_history = {}

local function close_peek()
  pcall(vim.api.nvim_del_augroup_by_name, "gtags_peek")
  if peek_window and vim.api.nvim_win_is_valid(peek_window) then
    vim.api.nvim_win_close(peek_window, true)
  end
  peek_window = nil
end

---@param opts? { chained?: boolean, view?: table } chained: opened from inside
---a peek, so the history is kept; view: scroll position to restore.
local function open_peek(symbol, items, opts)
  opts = opts or {}
  close_peek()
  if not opts.chained then
    peek_history = {}
  end
  local item = items[1]
  local origin = vim.api.nvim_get_current_win()
  -- Recorded now, while the cursor is still here: by the time Enter is pressed
  -- the window has been moved about and reading the position back is a race.
  local origin_pos = vim.fn.getpos(".")
  origin_pos[1] = vim.api.nvim_get_current_buf()

  -- Read the lines through a buffer rather than off disk: that way a Shift-JIS
  -- source is decoded the same way it would be when opened.
  local source = vim.fn.bufadd(item.filename)
  -- Another Neovim may hold a swap file for this source; loading it would stop
  -- to ask what to do with it. Reading it here is harmless, so skip the prompt.
  local shortmess = vim.o.shortmess
  vim.opt.shortmess:append("A")
  pcall(vim.fn.bufload, source)
  vim.o.shortmess = shortmess
  -- Four tenths of the screen, so most of a function shows while the code it
  -- is called from keeps the larger part; never under fourteen rows, which
  -- was the height on every screen and left a forty-line function half seen.
  local height = math.max(14, math.floor(vim.o.lines * 0.4))
  local first = math.max(item.lnum - 2, 1)
  -- Copy far past what the window shows, so the rest of a long function can be
  -- scrolled to inside it. The window still opens on the definition.
  local last = math.min(first + 400, vim.api.nvim_buf_line_count(source))
  local lines = vim.api.nvim_buf_get_lines(source, first - 1, last, false)

  -- A scratch copy, so keymaps and the cursor here cannot touch the real file.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = vim.bo[source].filetype
  vim.bo[buf].modifiable = false

  -- Put the window in the empty space to the right of the code, so the lines
  -- being read stay visible. When the definition does not fit there it lies
  -- over the code instead, below the cursor line or above it, whichever has the
  -- room: either way the line the cursor is on stays uncovered.
  local view = vim.fn.winsaveview()
  local win_width, win_height = vim.api.nvim_win_get_width(origin), vim.api.nvim_win_get_height(origin)
  local visible = vim.api.nvim_buf_get_lines(0, view.topline - 1, view.topline - 1 + win_height, false)
  local code_width = 0
  for _, line in ipairs(visible) do
    code_width = math.max(code_width, vim.fn.strdisplaywidth(line))
  end
  local gutter = vim.fn.getwininfo(origin)[1].textoff
  local beside = math.min(100, math.max(win_width - gutter - code_width - 4, 0))
  local wanted_height = math.min(#lines, height)
  local cursor_row = vim.fn.winline() - 1

  -- Rows free on each side of the cursor line, less the two border rows.
  -- Two rows are left blank between the window and the line being read. The
  -- window still looked as if it sat on that line on a real terminal when the
  -- clearance was a single row, so the margin is explicit rather than derived.
  local gap = 2

  -- The room is counted on the whole screen, not in the window: there is one
  -- peek at a time, and in a short split the window held it to a few rows
  -- while the screen above stood free. Rows are on the screen from here on,
  -- and turned into the window's own for nvim_open_win.
  local win_top = vim.fn.win_screenpos(origin)[1] - 1
  local tabline = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
  local screen_bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus == 3 and 1 or 0)
  local cursor_screen = win_top + cursor_row

  local function room(side)
    return side == "above" and (cursor_screen - tabline - 2 - gap) or (screen_bottom - cursor_screen - 3 - gap)
  end

  local function geometry(side)
    local h = math.max(math.min(wanted_height, room(side)), 3)
    local row = side == "above" and (cursor_screen - h - 1 - gap) or (cursor_screen + 2 + gap)
    return { height = h, row = row - win_top }
  end

  -- A window in the empty space to the right of the longest visible line cannot
  -- hide any code, so it keeps away from neither the cursor line nor the edges
  -- of the window. Only a window laid over the code has to dodge.
  --
  -- It goes there only when the lines it opens on fit: a trailing comment on
  -- one visible line can leave a strip too narrow for a C definition, which
  -- then wraps into something that cannot be read. The width the definition
  -- needs counts its line-number column.
  local needed = 0
  for i = 1, wanted_height do
    needed = math.max(needed, vim.fn.strdisplaywidth(lines[i]))
  end
  needed = math.min(needed + 6, 100)
  local clear_of_code = beside >= math.max(needed, 60)

  local col, width
  if clear_of_code then
    col, width = win_width - beside - 2, beside
  else
    col, width = 0, math.min(100, math.max(win_width - 2, 40))
  end

  -- Prefer below when the window fits there, or when below has the more room.
  local sides
  if room("below") >= wanted_height or room("below") >= room("above") then
    sides = { "below", "above" }
  else
    sides = { "above", "below" }
  end
  local chosen = geometry(sides[1])
  if clear_of_code then
    -- Level with the cursor, so the definition reads next to the call, and as
    -- tall as the window allows: a short window left this at three rows while
    -- the whole column beside it stood empty.
    local h = math.max(math.min(wanted_height, screen_bottom - tabline - 2), 3)
    local row = math.min(math.max(cursor_screen - math.floor(h / 2), tabline), math.max(screen_bottom - h - 2, tabline))
    chosen = { height = h, row = row - win_top }
  end

  peek_window = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = origin,
    row = chosen.row,
    col = col,
    width = width,
    height = chosen.height,
    border = "rounded",
    title = (" %s:%d%s "):format(
      vim.fn.fnamemodify(item.filename, ":t"),
      item.lnum,
      #items > 1 and (" (1/" .. #items .. ")") or ""
    ),
    title_pos = "center",
    style = "minimal",
  })

  -- The line under the cursor has to stay readable. The arithmetic above has
  -- been wrong more than once, so the position is measured after the window is
  -- open and moved until the line is clear: the other side first, then a row
  -- further away each time.
  local function frame()
    local pos = vim.fn.win_screenpos(peek_window)
    return pos[1] - 1, pos[1] + vim.api.nvim_win_get_height(peek_window)
  end

  local function covers_cursor_line()
    if clear_of_code then
      return false
    end
    local top, bottom = frame()
    local cursor_screen = vim.fn.win_screenpos(origin)[1] + cursor_row
    return cursor_screen >= top - gap and cursor_screen <= bottom + gap
  end

  local function move_to(row, h)
    vim.api.nvim_win_set_config(peek_window, {
      relative = "win",
      win = origin,
      row = row,
      col = col,
      width = width,
      height = h,
    })
  end

  -- Pull the edge that faces the cursor line back by `nudge` rows: the bottom
  -- of a window above it, the top of a window below it. Shrinking the other
  -- edge leaves the covering one where it is.
  local function backed_off(side, g, nudge)
    local h = math.max(g.height - nudge, 3)
    return { row = side == "above" and g.row or (g.row + g.height - h), height = h }
  end

  local other = geometry(sides[2])
  local candidates = { { row = other.row, height = other.height } }
  for nudge = 1, 6 do
    candidates[#candidates + 1] = backed_off(sides[1], chosen, nudge)
    candidates[#candidates + 1] = backed_off(sides[2], other, nudge)
  end
  -- Try the roomiest placements first: a window squeezed into three rows is
  -- worse than one on the other side of the cursor.
  table.sort(candidates, function(a, b)
    return a.height > b.height
  end)
  for _, candidate in ipairs(candidates) do
    if not covers_cursor_line() then
      break
    end
    move_to(candidate.row, candidate.height)
  end

  local top, bottom = frame()
  peek_debug = (
    "win=%dx%d cursor_row=%d | room above=%d below=%d beside=%d need=%d code=%d gutter=%d"
    .. " | side=%s col=%d width=%d | row=%d height=%d frame=[%d..%d] cursor_screen=%d covers=%s"
  ):format(
    win_width,
    win_height,
    cursor_row,
    room("above"),
    room("below"),
    beside,
    needed,
    code_width,
    gutter,
    clear_of_code and "beside" or sides[1],
    col,
    width,
    vim.api.nvim_win_get_config(peek_window).row,
    vim.api.nvim_win_get_height(peek_window),
    top,
    bottom,
    vim.fn.win_screenpos(origin)[1] + cursor_row,
    tostring(covers_cursor_line())
  )

  vim.wo[peek_window].cursorline = true
  -- The copy starts partway into the file, so show the line numbers it had
  -- there; scrolling inside the window otherwise loses track of where it is.
  vim.wo[peek_window].number = true
  vim.wo[peek_window].statuscolumn = ("%%{v:lnum + %d} "):format(first - 1)
  vim.api.nvim_win_set_cursor(peek_window, { item.lnum - first + 1, 0 })
  -- The definition line keeps its own highlight: the cursor line follows the
  -- cursor, so after scrolling down a long function nothing else marks where
  -- the definition was. Visual is the selection color every colorscheme makes
  -- easy to spot; the link is a default, so a colorscheme that defines
  -- GtagsPeekDefinition itself wins, and it is set here rather than once at
  -- setup so that a colorscheme loaded later cannot leave it undefined.
  vim.api.nvim_set_hl(0, "GtagsPeekDefinition", { default = true, link = "Visual" })
  vim.api.nvim_buf_set_extmark(buf, peek_marks, item.lnum - first, 0, { line_hl_group = "GtagsPeekDefinition" })
  if opts.view then
    -- Coming back with <C-t>: the place that was being read, not the top.
    vim.fn.winrestview(opts.view)
  end

  -- Bound in visual mode as well: dragging the mouse across the window or
  -- pressing v leaves it selected, and Esc then only dropped the selection,
  -- so the window looked as if it could no longer be closed.
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set({ "n", "x" }, key, close_peek, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "<CR>", function()
    close_peek()
    vim.api.nvim_set_current_win(origin)
    show("Definitions of " .. symbol, symbol, { item }, origin_pos)
  end, { buffer = buf, nowait = true })

  -- The jump keys, pressed in here, show that definition in a fresh peek. Left
  -- to the global mappings they load the definition's file into this small
  -- window: the scratch copy goes, its close keys go with it, and the window
  -- can no longer be closed from the keyboard. Enter stays the key that leaves.
  -- The lookup runs from the window the peek was opened from, because the
  -- scratch copy has no file name to find a GTAGS from.
  local function back_to_origin()
    close_peek()
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end

  local function peek_earlier()
    local earlier = table.remove(peek_history)
    if not earlier then
      return false
    end
    back_to_origin()
    open_peek(earlier.symbol, earlier.items, { chained = true, view = earlier.view })
    return true
  end

  local function peek_again(word)
    peek_history[#peek_history + 1] = { symbol = symbol, items = items, view = vim.fn.winsaveview() }
    back_to_origin()
    -- A word with no definition would otherwise close the peek being read.
    peek_definition(word, { chained = true, on_missing = peek_earlier })
  end

  -- <C-t> walks back through the peeks the way it does through real jumps.
  vim.keymap.set("n", "<C-t>", function()
    if not peek_earlier() then
      vim.notify("No earlier peek", vim.log.levels.INFO)
    end
  end, { buffer = buf, nowait = true })
  for _, key in ipairs({ "<C-]>", "<leader>jp", "<leader>jg" }) do
    vim.keymap.set("n", key, function()
      peek_again(vim.fn.expand("<cword>"))
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "<C-LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= peek_window or pos.line == 0 then
      -- A click outside the peek is an ordinary jump from where it landed.
      close_peek()
      if pos.winid ~= 0 and pos.line > 0 then
        vim.api.nvim_set_current_win(pos.winid)
        vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.column - 1, 0) })
      end
      return jump_to_definition(vim.fn.expand("<cword>"), "click")
    end
    vim.api.nvim_win_set_cursor(peek_window, { pos.line, math.max(pos.column - 1, 0) })
    peek_again(vim.fn.expand("<cword>"))
  end, { buffer = buf, nowait = true })

  local group = vim.api.nvim_create_augroup("gtags_peek", { clear = true })
  -- Leaving the window for any reason, a click elsewhere included, closes it.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_win() == peek_window then
        close_peek()
      end
    end,
  })
  -- Whatever else loads a buffer into this window (:edit, gf, a picker) is
  -- handed to the window the peek was opened from, and the peek closes: the
  -- window only ever shows its scratch copy.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        if not (peek_window and vim.api.nvim_win_is_valid(peek_window)) then
          return
        end
        local stray = vim.api.nvim_win_get_buf(peek_window)
        if stray == buf then
          return
        end
        local cursor = vim.api.nvim_win_get_cursor(peek_window)
        close_peek()
        if vim.api.nvim_win_is_valid(origin) then
          vim.api.nvim_set_current_win(origin)
          vim.api.nvim_win_set_buf(origin, stray)
          pcall(vim.api.nvim_win_set_cursor, origin, cursor)
        end
      end)
    end,
  })
end

---@param opts? { chained?: boolean, on_missing?: fun() } on_missing runs when
---there is nothing to show, after the warning.
function peek_definition(symbol, opts)
  opts = opts or {}
  local function missing(message)
    vim.notify(message, vim.log.levels.WARN)
    if opts.on_missing then
      opts.on_missing()
    end
  end
  if not symbol or symbol == "" then
    return missing("No word under the cursor")
  end
  -- gtags first and ctags where it has nothing, as a jump looks a name up, so
  -- that a peek finds whatever <C-]> would go to.
  local function show_or_ctags(items)
    if #items == 0 then
      items = ctags_definitions(symbol)
    end
    if #items == 0 then
      missing("No definition found for " .. symbol)
    else
      open_peek(symbol, items, { chained = opts.chained })
    end
  end
  lookup_definition(symbol, show_or_ctags, function()
    show_or_ctags({})
  end)
end

local M = {}

M.peek = peek_definition

-- Where the last peek window landed, for :GtagsPeekDebug.
function M.debug()
  return peek_debug
end

return M

-- cscope-style navigation for legacy C using GNU Global (gtags) as backend.
--
-- Why not vim-gutentags? Neovim >=0.9 dropped built-in cscope support, so
-- gutentags's `gtags_cscope` module aborts at load. cscope_maps.nvim
-- reimplements the cscope command set in Lua and talks to `gtags-cscope`
-- directly.
--
-- Why a custom `:!gtags` build binding? cscope_maps's `:Cs db build` always
-- appends `-d <file>::<path>` to the build command for cscope semantics, but
-- the `gtags` binary doesn't accept `-d` — leaving it as the configured
-- builder yields "database build failed".
--
-- Why prefix `<leader>j` (not `<leader>c`)? `<leader>c*` is LazyVim's code
-- namespace (format, action, rename, etc.) and would collide.
--
-- Requires `gtags` on PATH (scoop install global, or winget GNU.GLOBAL).

-- Every query here asks `global` directly instead of going through cscope_maps.
--
-- cscope_maps answers each query by starting gtags-cscope.exe, which starts
-- global.exe, and waits for both with vim.system():wait(), freezing the editor
-- until they exit. Asking global directly drops one process start (117 ms to
-- 36 ms per lookup on the openssl tree), and running it asynchronously means
-- the editor keeps responding however slow process starts are made by security
-- software. Each cscope query has a global equivalent that returns the same
-- matches: definitions -d, references -r, other symbols -s, text -g, files -P.
--
-- How global is started lives in config/gtags_global.lua, which also handles a
-- global.exe that cannot write its results to Neovim's pipe.
--
-- A resident gtags-cscope was measured and rejected: it still starts global.exe
-- for every query. Loading every definition up front was rejected too: it is
-- instant on openssl but takes over a minute and 1.3 GB on a Linux kernel tree.
--
-- The database is picked from the file being edited, not from the cwd, so a
-- file opened from another project -- routine with the remote-tab workflow in
-- bin/open-in-nvim.cmd -- queries its own GTAGS.

-- Definition results are kept per project until its GTAGS changes, so a
-- repeated jump starts no process at all. Other queries are not cached: they
-- are browsed, not repeated.
local definitions = {} ---@type table<string, { mtime: integer, symbols: table<string, table[]> }>

local function definitions_of(root)
  local stat = vim.uv.fs_stat(vim.fs.joinpath(root, "GTAGS"))
  local mtime = stat and stat.mtime.sec or 0
  local project = definitions[root]
  if not project or project.mtime ~= mtime then
    project = { mtime = mtime, symbols = {} }
    definitions[root] = project
  end
  return project.symbols
end

local function gtags_root()
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and vim.fs.root(name, "GTAGS") or nil
end

-- `global -ax*` prints `name  line  absolute-path  source-line`.
local function parse(output)
  local items = {}
  for line in vim.gsplit(output, "\n", { trimempty = true }) do
    local lnum, file, text = line:gsub("\r$", ""):match("^%S+%s+(%d+)%s+(%S+)%s?(.*)$")
    if lnum then
      items[#items + 1] = { filename = file, lnum = tonumber(lnum), col = 1, text = vim.trim(text) }
    end
  end
  return items
end

local function jump_with_ctags(symbol)
  if not pcall(vim.cmd.tjump, symbol) then
    vim.notify("No definition found for " .. symbol, vim.log.levels.WARN)
  end
end

local function open_picker(title, items)
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if Snacks and Snacks.picker then
    Snacks.picker.qflist()
  else
    vim.cmd.copen()
  end
end

-- One result opens directly; several open in the quickfix picker. Either way
-- the origin is pushed on the tag stack, so <C-t> returns here.
---@param from? table position recorded by the caller, for when the jump starts
---from somewhere the cursor has already left, such as the peek window.
local function show(title, symbol, items, from)
  if not from then
    from = vim.fn.getpos(".")
    from[1] = vim.api.nvim_get_current_buf()
  end
  vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = { { tagname = symbol, from = from } } }, "t")
  if #items == 1 then
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(items[1].filename))
    vim.api.nvim_win_set_cursor(0, { items[1].lnum, 0 })
    vim.cmd("normal! ^")
    return
  end
  open_picker(title, items)
end

-- Run one or more `global` invocations in the project root and hand the merged
-- results to `done`, on the main loop, only if the user is still where they
-- asked from.
local function run_global(root, invocations, done)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local items, pending = {}, #invocations
  for _, args in ipairs(invocations) do
    require("config.gtags_global").run(root, args, function(output)
      vim.list_extend(items, parse(output))
      pending = pending - 1
      if pending == 0 and vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf then
        done(items)
      end
    end)
  end
end

---Look the definitions of `symbol` up and hand them to `done`. `done` is not
---called when there is no database or no global to ask.
local function lookup_definition(symbol, done, no_database)
  local root = gtags_root()
  if not root or vim.fn.executable("global") == 0 then
    return no_database()
  end
  local symbols = definitions_of(root)
  local function finish(items)
    symbols[symbol] = items
    done(items)
  end
  if symbols[symbol] then
    return finish(symbols[symbol])
  end
  run_global(root, { { "-axd", symbol } }, finish)
end

local function jump_to_definition(symbol)
  if not symbol or symbol == "" then
    return
  end
  lookup_definition(symbol, function(items)
    if #items == 0 then
      -- gtags has no entry, e.g. for a source it could not parse.
      jump_with_ctags(symbol)
    else
      show("Definitions of " .. symbol, symbol, items)
    end
  end, function()
    jump_with_ctags(symbol)
  end)
end

-- Read a definition without leaving the current position: a window opens under
-- the cursor with the code around the definition, and the file being read stays
-- on screen around it. q or Esc closes it, Enter jumps there after all. Nothing
-- is pushed on the tag stack until something actually moves.
local peek_window
local peek_debug = "(no window opened yet)"

local function close_peek()
  if peek_window and vim.api.nvim_win_is_valid(peek_window) then
    vim.api.nvim_win_close(peek_window, true)
  end
  peek_window = nil
end

local function open_peek(symbol, items)
  close_peek()
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
  local height = 14
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
  -- being read stay visible. When that space is too narrow it sits under the
  -- cursor instead, or above it when the cursor is near the bottom: either way
  -- the line the cursor is on stays uncovered.
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

  local function room(side)
    return side == "above" and (cursor_row - 2 - gap) or (win_height - cursor_row - 3 - gap)
  end

  local function geometry(side)
    local h = math.max(math.min(wanted_height, room(side)), 3)
    return { height = h, row = side == "above" and (cursor_row - h - 1 - gap) or (cursor_row + 2 + gap) }
  end

  -- A window in the empty space to the right of the longest visible line cannot
  -- hide any code, so it keeps away from neither the cursor line nor the edges
  -- of the window. Only a window laid over the code has to dodge.
  local clear_of_code = beside >= 50

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
    local h = math.max(math.min(wanted_height, win_height - 2), 3)
    local row = math.min(math.max(cursor_row - math.floor(h / 2), 0), math.max(win_height - h - 2, 0))
    chosen = { height = h, row = row }
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
    "win=%dx%d cursor_row=%d | room above=%d below=%d beside=%d code=%d gutter=%d"
    .. " | side=%s col=%d width=%d | row=%d height=%d frame=[%d..%d] cursor_screen=%d covers=%s"
  ):format(
    win_width,
    win_height,
    cursor_row,
    room("above"),
    room("below"),
    beside,
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
  -- Leaving the window for any reason, a click elsewhere included, closes it.
  -- Scoped to this buffer so it cannot fire on a move between other windows.
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close_peek })
end

local function peek_definition(symbol)
  if not symbol or symbol == "" then
    return
  end
  lookup_definition(symbol, function(items)
    if #items == 0 then
      vim.notify("No definition found for " .. symbol, vim.log.levels.WARN)
    else
      open_peek(symbol, items)
    end
  end, function()
    vim.notify("No GTAGS for this file", vim.log.levels.WARN)
  end)
end

-- The cscope-style queries behind <leader>j*.
local queries = {
  -- -s finds names gtags does not record as definitions, such as enum members;
  -- without it an enum constant used 103 times shows no occurrences at all.
  s = {
    title = "Occurrences of",
    args = function(s)
      return { { "-axd", s }, { "-axr", s }, { "-axs", s } }
    end,
  },
  c = {
    title = "Callers of",
    args = function(s)
      return { { "-axr", s } }
    end,
  },
  t = {
    title = "Text",
    args = function(s)
      return { { "-axg", "--literal", s } }
    end,
  },
  f = {
    title = "Files matching",
    args = function(s)
      return { { "-axP", s } }
    end,
  },
  -- gtags does not index #include, so match the directive text instead.
  i = {
    title = "Files including",
    args = function(s)
      local name = vim.fn.escape(vim.fs.basename(s), [[.^$*+?()[]{}|\]])
      return { { "-axg", [=[#[ \t]*include[ \t]*["<](.*/)?]=] .. name .. [=[[">]]=] } }
    end,
  },
}

local function query(kind, symbol)
  local spec = queries[kind]
  if not symbol or symbol == "" then
    return
  end
  local root = gtags_root()
  if not root then
    vim.notify("No GTAGS for this file. Build one with <leader>jb in the project root.", vim.log.levels.WARN)
    return
  end
  if vim.fn.executable("global") == 0 then
    vim.notify("global is not on PATH", vim.log.levels.ERROR)
    return
  end
  run_global(root, spec.args(symbol), function(items)
    if #items == 0 then
      vim.notify(("%s %s: nothing found"):format(spec.title, symbol), vim.log.levels.WARN)
    else
      show(("%s %s"):format(spec.title, symbol), symbol, items)
    end
  end)
end

local function selected_text()
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return vim.trim(region[1] or "")
end

-- The file queries take the file name under the cursor, the rest the word.
local function under_cursor(kind)
  return vim.fn.expand((kind == "f" or kind == "i") and "<cfile>" or "<cword>")
end

local function query_key(lhs, kind, desc)
  return {
    {
      lhs,
      function()
        query(kind, under_cursor(kind))
      end,
      desc = desc,
    },
    {
      lhs,
      function()
        query(kind, selected_text())
      end,
      desc = desc,
      mode = "x",
    },
  }
end

-- Ctrl+click: move the cursor to what was clicked, then jump. Vim's built-in
-- <C-LeftMouse> runs `:tag <cword>` directly and bypasses any remap of <C-]>.
local function jump_at_mouse()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= 0 and pos.line > 0 then
    vim.api.nvim_set_current_win(pos.winid)
    vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.column - 1, 0) })
  end
  jump_to_definition(vim.fn.expand("<cword>"))
end

local keys = {
  {
    "<C-]>",
    function()
      jump_to_definition(vim.fn.expand("<cword>"))
    end,
    desc = "Jump to definition",
  },
  {
    "<C-]>",
    function()
      jump_to_definition(selected_text())
    end,
    desc = "Jump to definition",
    mode = "x",
  },
  { "<C-LeftMouse>", jump_at_mouse, desc = "Jump to definition (Ctrl+click)", mode = { "n", "x" } },
  {
    "<leader>jp",
    function()
      peek_definition(vim.fn.expand("<cword>"))
    end,
    desc = "Peek definition",
  },
  {
    "<leader>jp",
    function()
      peek_definition(selected_text())
    end,
    desc = "Peek definition",
    mode = "x",
  },
  { "<leader>jb", "<cmd>!gtags<cr>", desc = "Build gtags DB (cwd)" },
  {
    "<leader>jg",
    function()
      jump_to_definition(vim.fn.expand("<cword>"))
    end,
    desc = "Find global definition",
  },
  {
    "<leader>jg",
    function()
      jump_to_definition(selected_text())
    end,
    desc = "Find global definition",
    mode = "x",
  },
}
for _, k in ipairs({
  { "<leader>js", "s", "Find this symbol" },
  { "<leader>jc", "c", "Find callers" },
  { "<leader>jt", "t", "Find this text string" },
  { "<leader>jf", "f", "Find file" },
  { "<leader>ji", "i", "Find files #including this" },
}) do
  vim.list_extend(keys, query_key(k[1], k[2], k[3]))
end

return {
  "dhananjaylatkar/cscope_maps.nvim",
  event = "VeryLazy",
  init = function()
    -- C identifiers are case-sensitive. With the default "followic" and
    -- LazyVim's ignorecase, the ctags fallback treats SSL_new and ssl_new as the
    -- same tag and stops to ask which one was meant.
    vim.opt.tagcase = "match"

    -- Shows which way global is being started, to tell a missing index from a
    -- global.exe whose output never reaches Neovim.
    -- Reports where the last peek window landed, for when it still covers the
    -- line it was supposed to keep visible.
    vim.api.nvim_create_user_command("GtagsPeekDebug", function()
      vim.notify(peek_debug)
    end, {})

    vim.api.nvim_create_user_command("GtagsTransport", function(opts)
      local global = require("config.gtags_global")
      if opts.args == "reset" then
        global.reset()
      end
      vim.notify(global.status())
    end, {
      nargs = "?",
      complete = function()
        return { "reset" }
      end,
    })
  end,
  keys = keys,
  opts = {
    disable_maps = true,
    cscope = {
      -- cscope_maps binds <C-]> to :Cstag from its own setup, which runs after
      -- the keys above and would win.
      tag = { keymap = false },
      db_file = "./GTAGS",
      exec = "gtags-cscope",
      picker = "snacks",
      skip_picker_for_single_result = true,
      project_rooter = {
        enable = true,
      },
    },
  },
}

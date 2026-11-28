-- A trace: the path through the code that a bug takes, or any reading of code
-- written down step by step, each step a place with a short title and a note
-- that explains it (lua/taka/trace/store.lua has the file). It is read from a
-- file someone else writes, a person or a tool tracing the code, and shown two
-- ways without a word of the source changed:
--
--   in the code      each step's number in the sign column and its title in
--                    a line of its own above the line, set off by a bar in
--                    the colour of its kind (a cause red, a suspect yellow);
--                    the step chosen also has its note there, or every step
--                    does with N in the panel; <leader>uR puts the notes
--                    away and shows them again
--   in the panel     the steps as a tree on the right (<leader>ja), each
--                    under the step it came from; moving through the rows
--                    shows each step in the code beside it
--
-- ]n and [n go to the next and the previous step from the code. The file is
-- read again whenever it changes, so a trace grows on the screen while it is
-- written, and while the newest trace is followed a new one replaces it.
local M = {}

local store = require("taka.trace.store")
local editors = require("taka.trace.editors")

local namespace = vim.api.nvim_create_namespace("config_trace")

-- The trace shown: the file, the trace read from it and its rows in order,
-- the step chosen last, whether the newest file is followed (not when one was
-- picked), whether the notes show in the code at all (<leader>uR) and
-- whether every step shows its note there, not only the step chosen (N in the
-- panel).
local state = {
  path = nil,
  trace = nil,
  rows = {},
  current = nil,
  -- Whether the code shows the function of the step chosen, from its heading
  -- in the panel, rather than the step's own line.
  on_function = false,
  follow = true,
  notes = true,
  all_notes = false,
  located = {},
  -- By buffer, the notes stacked over each line (see M.decorate).
  stacks = {},
}

-- The colour of a step goes by its kind, from the diagnostics, which every
-- scheme sets: a cause in the colour of an error, a suspect of a warning, an
-- answer, the step a question about the code is answered at, of a check passed,
-- the rest of information. The step chosen shows its note on a card: a block on
-- the colour of paper, its number on a label of the kind's colour. Italic text
-- in a colour of its own, the way the note first was, read as more code at a
-- glance, the thin bar beside it too little to tell where the note ended; a
-- background marks the whole of it as something laid over the code, as a
-- comment of a review is. A step not chosen has its title on the same
-- background in dimmer text, and the line of the step chosen last is tinted as
-- a diagnostic's text is.
local KINDS = {
  TraceStep = "DiagnosticInfo",
  TraceCause = "DiagnosticError",
  TraceSuspect = "DiagnosticWarn",
  TraceAnswer = "DiagnosticOk",
}

-- `a` laid over `b` at `amount`, both colours as numbers.
local function mix(a, b, amount)
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local x = bit.band(bit.rshift(a, shift), 255)
    local y = bit.band(bit.rshift(b, shift), 255)
    out = out + bit.lshift(math.floor(x * amount + y * (1 - amount) + 0.5), shift)
  end
  return out
end

local function colours()
  local function set(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local light = vim.o.background == "light"
  -- A terminal's own background, where the scheme leaves it to the terminal.
  local bg = normal.bg or (light and 0xffffff or 0x000000)
  local fg = normal.fg or (light and 0x000000 or 0xffffff)
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false }).fg or fg
  -- The mark of a step the reader has edited, in a colour of its own.
  local edited = vim.api.nvim_get_hl(0, { name = "DiagnosticHint", link = false }).fg or fg
  -- One colour for every note, of paper, the colour of a note stuck on a page,
  -- laid over the scheme's background so it sits in a dark scheme or a light
  -- one; the kind of a step is the colour of its label alone. Each card took
  -- the colour of its kind before, which made blue the colour of a note, the
  -- colour of the code's own names. The bar at its left edge is the paper's
  -- colour, deeper: where the note begins, nothing more.
  local paper = 0xd9bf86
  local card = mix(paper, bg, light and 0.35 or 0.2)
  local edge = mix(paper, bg, 0.7)
  for group, diagnostic in pairs(KINDS) do
    set(group, { link = diagnostic })
    local colour = vim.api.nvim_get_hl(0, { name = diagnostic, link = false }).fg or fg
    set(group .. "Card", { fg = fg, bg = card })
    set(group .. "Bar", { fg = edge, bg = card })
    set(group .. "Head", { fg = fg, bg = card, bold = true })
    set(group .. "Label", { fg = bg, bg = colour, bold = true })
    set(group .. "Lost", { fg = warn, bg = card })
    set(group .. "Edited", { fg = edited, bg = card })
    -- The line of a step not chosen: on the card's background, its text
    -- between the card's and the background's, so it is not taken for a
    -- comment of the code, as dim italics were, and gives way to the card.
    set(group .. "Line", { fg = mix(fg, bg, 0.7), bg = card })
  end
  set("TraceEdited", { link = "DiagnosticHint" })
  -- The line of the step chosen: the background of an info note under the
  -- code, and no colour of text. Linked to the note's own colours, its cyan
  -- text took the whole line and put out the colours of the code on it.
  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticVirtualTextInfo", link = false })
  set("TraceCurrent", { bg = info.bg or card })
  set("TraceLost", { link = "DiagnosticWarn" })
  -- The file of a place in the panel: the text of the sidebar, unlit.
  set("TraceFile", { link = "SnacksPickerFile" })
  -- The heading of the steps in one function: in the colour of a function's
  -- name, so it is told from the titles of the steps under it.
  set("TraceFunction", { link = "Function" })
  -- The lines of the calls a row is inside: the colour of the guides of the
  -- indent in the code.
  set("TraceCallGuide", { link = "SnacksIndent" })
  -- The number of steps a folded heading holds.
  set("TraceFolded", { link = "Comment" })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_trace_colours", { clear = true }),
  callback = colours,
})

local KIND_COLOUR = { cause = "TraceCause", suspect = "TraceSuspect", answer = "TraceAnswer" }

function M.kind_colour(step)
  return KIND_COLOUR[step.kind] or "TraceStep"
end

-- `text` cut into lines no wider than `width` on the screen, at a space where
-- there is one in reach and anywhere in a run of text without spaces, as
-- Japanese is written.
local function wrap(text, width)
  local out = {}
  for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line, line_width = "", 0
    for char in paragraph:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local char_width = vim.fn.strdisplaywidth(char)
      if line_width + char_width > width then
        local head, tail = line:match("^(.*%S) +(%S*)$")
        if head and vim.fn.strdisplaywidth(tail) < width / 3 then
          out[#out + 1] = head
          line = tail
        else
          out[#out + 1] = line
          line = ""
        end
        line = char == " " and line or line .. char
        line_width = vim.fn.strdisplaywidth(line)
      else
        line, line_width = line .. char, line_width + char_width
      end
    end
    out[#out + 1] = line
  end
  return out
end

local BAR = "▎"

-- The mark of a step whose title and note the reader has edited (cod-edit of
-- the Nerd Font).
local EDITED = ""

-- The lines above a step, indented as the code line is so they read as
-- belonging to it. The step chosen, or every step while every note shows, has
-- a card: its number on a label and its title, then its note, every line
-- filled out to one width so the background makes a block. A step other than
-- the one chosen keeps to a line: its number on the same label and its title
-- on the card's background, as wide as the title, in dimmer text. Cards on
-- every step of a function pushed its lines apart until the code was hard to
-- read, while a line each still says where the other steps are; drawn dim and
-- in italics with no background, that line was taken for a comment of the
-- code. Its note, left out, is marked with an ellipsis.
local function note_lines(row, indent, width)
  local kind = M.kind_colour(row.step)
  local pad = { string.rep(" ", indent) }
  local lost = M.where(row.step).lost and "  (line not found)" or ""
  local edited = row.step.edited and (" " .. EDITED) or ""
  if not (state.all_notes or row.step.id == state.current) then
    return {
      {
        pad,
        { BAR, kind .. "Bar" },
        { (" %d "):format(row.number), kind .. "Label" },
        { " " .. row.step.title .. (row.step.note ~= "" and " …" or "") .. " ", kind .. "Line" },
        { edited, kind .. "Edited" },
        { lost, kind .. "Lost" },
      },
    }
  end
  local label = (" %d "):format(row.number)
  local title = " " .. row.step.title
  local body = {}
  for _, text in ipairs(row.step.note ~= "" and wrap(row.step.note, width) or {}) do
    body[#body + 1] = { "  " .. text, kind .. "Card" }
  end
  local function cells(text)
    return vim.fn.strdisplaywidth(text)
  end
  local head = cells(label) + cells(title) + cells(edited) + cells(lost)
  local inner = head
  for _, part in ipairs(body) do
    inner = math.max(inner, cells(part[1]))
  end
  inner = inner + 1
  local lines = {
    {
      pad,
      { BAR, kind .. "Bar" },
      { label, kind .. "Label" },
      { title, kind .. "Head" },
      { edited, kind .. "Edited" },
      { lost, kind .. "Lost" },
      { string.rep(" ", inner - head), kind .. "Card" },
    },
  }
  for _, part in ipairs(body) do
    lines[#lines + 1] = {
      pad,
      { BAR, kind .. "Bar" },
      { part[1] .. string.rep(" ", inner - cells(part[1])), part[2] },
    }
  end
  return lines
end

local function same_file(a, b)
  return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower()
end

-- Where a step's line is now in `buf`, and whether it was found there. A step
-- that gives the text of its line is on the line it names while that line
-- still says it, else on the nearest line that does: the code may have moved
-- since the trace was written, by an edit or an update, and the line number
-- written may be off. A line it is not found on at all is marked, so a step
-- never points at the wrong line without a word. A step with no text is on
-- the line it names.
function M.locate(buf, step)
  return M.locate_in(vim.api.nvim_buf_get_lines(buf, 0, -1, false), step)
end

-- The same in the lines of a file not read into a buffer.
function M.locate_in(lines, step)
  local fallback = math.max(1, math.min(step.line, #lines))
  if step.text == "" then
    return fallback, true
  end
  -- A part of a line is taken too, but not so short a part that it is found
  -- anywhere.
  local function says(number)
    local line = lines[number]
    if not line then
      return false
    end
    line = store.squash(line)
    return line == step.text or (#step.text >= 8 and line:find(step.text, 1, true) ~= nil)
  end
  if says(step.line) then
    return step.line, true
  end
  for distance = 1, #lines do
    for _, number in ipairs({ step.line - distance, step.line + distance }) do
      if says(number) then
        return number, true
      end
    end
  end
  return fallback, false
end

-- Where a step was last found: its line, and whether it was lost. Until its
-- file is read, the line it names.
function M.where(step)
  local found = state.located[step.id]
  return found or { line = step.line, lost = false }
end

-- The function a step's line is in, "" where it is in none or it cannot be
-- told: from the file's buffer where it is open, else, for C, from the file
-- on disk, which needs no buffer loaded for a step not looked at yet. Worked
-- out from the code, not written in the trace: a name written there would go
-- wrong as the code moves, and the line already says it.
function M.function_of(step)
  local line = M.where(step).line
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and same_file(vim.api.nvim_buf_get_name(buf), step.file) then
      return require("taka.lib.enclosing").at(buf, line)
    end
  end
  local kind = vim.filetype.match({ filename = step.file })
  if (kind == "c" or kind == "cpp") and vim.uv.fs_stat(step.file) then
    return require("taka.lib.c_outline").function_at(step.file, line) or ""
  end
  return ""
end

-- Draws the steps of the trace that are in one buffer. True when a step was
-- found on another line than before, for the panel to show.
function M.decorate(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or not state.trace then
    return
  end
  local moved = false
  -- The text area of the narrowest window the buffer is in, which a line of
  -- the note must fit: one that does not is cut off at the edge, not wrapped.
  local room
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    room = math.min(room or math.huge, info.width - info.textoff)
  end
  room = room or vim.o.columns
  -- The notes over each line, top to bottom, as Neovim stacks the marks of one
  -- line in the order they are made: which step each is and how many rows it
  -- takes, for a click to be told apart where two steps share a line.
  local stacks = {}
  state.stacks[buf] = stacks
  for _, row in ipairs(state.rows) do
    if same_file(row.step.file, name) then
      local line, found = M.locate(buf, row.step)
      local before = state.located[row.step.id]
      if not before or before.line ~= line or before.lost == found then
        moved = true
      end
      state.located[row.step.id] = { line = line, lost = not found }
      local indent = vim.api.nvim_buf_call(buf, function()
        return vim.fn.indent(line)
      end)
      -- Past a hundred columns a line is hard to follow back to its start.
      local note = state.notes and note_lines(row, indent, math.max(20, math.min(100, room - indent - 6))) or nil
      vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
        sign_text = row.number < 100 and ("%2d"):format(row.number) or "··",
        sign_hl_group = found and M.kind_colour(row.step) or "TraceLost",
        virt_lines = note,
        virt_lines_above = true,
        priority = 20,
      })
      -- The line of the step chosen, to the edge of the window. Not a line
      -- highlight: that is drawn over every other colour on the line, and
      -- hides the word under the cursor lit there.
      if state.notes and row.step.id == state.current then
        vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
          end_row = line,
          end_col = 0,
          hl_group = "TraceCurrent",
          hl_eol = true,
          priority = 20,
        })
      end
      stacks[line] = stacks[line] or {}
      table.insert(stacks[line], { row = row, height = note and #note or 0 })
    end
  end
  return moved
end

local function decorate_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.decorate(buf)
  end
end

local function panel()
  return require("taka.trace.panel")
end

-- The trace and its rows, for the panel and the checks.
function M.state()
  return state
end

local function read_again()
  if not state.path then
    return
  end
  state.trace = store.read(state.path)
  state.rows = store.outline(state.trace)
  state.located = {}
  -- A step whose file is not there is lost, whatever it says: shown, it
  -- opened an empty buffer of that name, and its row read as a step found.
  for _, row in ipairs(state.rows) do
    if not vim.uv.fs_stat(row.step.file) then
      state.located[row.step.id] = { line = row.step.line, lost = true }
    end
  end
  decorate_all()
  panel().refresh()
  -- Lines left out are told once for each change in them, not at every read.
  local problems = state.trace.problems
  local said = ("%s|%d|%s"):format(state.path, #problems, problems[1] and problems[1].line or "")
  if #problems > 0 and said ~= state.said then
    vim.notify(
      ("Trace %s: %d lines could not be read (:TraceCheck lists them)"):format(
        vim.fn.fnamemodify(state.path, ":t"),
        #problems
      ),
      vim.log.levels.WARN
    )
  end
  state.said = #problems > 0 and said or nil
end

-- The files are watched as a folder, through the system's notice of a change
-- and not by looking again and again: nothing runs while nothing is written.
-- A file written in pieces sends a notice per piece, so the reading waits for
-- them to stop, and then looks at the files the notices named. The watch
-- starts with the editor's screen (M.lookout), so that a trace written before
-- any was shown is shown as it comes, or else with the first trace shown.
local watcher, settle_timer, watched
local changed = {}
-- Whether the folder is watched from the start, kept watched when the trace
-- is put away.
local lookout = false
-- The traces told of and not shown: one written a step at a time is told of
-- once, not at each step.
local told = {}

local function on_change()
  local names = changed
  changed = {}
  if names[""] then
    names[""] = nil
    local newest = store.files()[1]
    if newest then
      names[vim.fs.basename(newest.path)] = true
    end
  end
  -- The project of the file read now: taken once when the trace was opened,
  -- it stayed after a move to another project, whose traces were then left
  -- out as another's.
  state.project = M.project()
  local again = false
  for name in pairs(names) do
    local path = vim.fs.normalize(vim.fs.joinpath(store.dir(), name))
    local trace_file = name:match("%.jsonl?$") and vim.uv.fs_stat(path)
    if path == state.path then
      again = true
    elseif trace_file and path ~= state.put_away then
      local root = store.root_of(path)
      if store.belongs(root, state.project) then
        if state.follow then
          state.path, state.current, again = path, nil, false
          read_again()
          vim.notify(("Trace: %s (%d steps)"):format(state.trace.title, #state.rows))
        elseif not told[path] then
          told[path] = true
          vim.notify(("New trace: %s (<leader>jA shows it)"):format(store.read(path).title))
        end
      elseif not told[path] then
        -- Not shown, and said why: left out without a word, a trace written
        -- for the wrong project looked like one never written.
        told[path] = true
        vim.notify(
          ("Trace %s is about %s, not this project (%s): <leader>jA, then <A-a>, shows it"):format(
            store.read(path).title,
            root,
            state.project
          ),
          vim.log.levels.WARN
        )
      end
    end
  end
  if again then
    read_again()
  end
end

-- The project being read: the folder over the current file that holds GTAGS,
-- .git or .svn; else the cwd, for a file under it; else the file's own folder,
-- as the pins find a file's project. Traces are kept together under Neovim's
-- data directory, out of the projects they are about, and are sorted out by
-- the root each gives: the newest shown, the one followed and those listed are
-- the current project's.
--
-- The folder that marks a file's project is looked for once for each file,
-- when it is first asked for or read again: the search reads every folder
-- above the file, which on a slow disk or a share is slow, and the project
-- is asked for at each move to another file (lua/taka/trace/editors.lua).
local marks = {} ---@type table<string, string|false>
function M.project()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local name = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or ""
  if name == "" then
    return cwd
  end
  if marks[name] == nil then
    local found = require("taka.lib.gtags_global").root(name, { ".git", ".svn" })
    marks[name] = found and vim.fs.normalize(found) or false
  end
  local marked = marks[name]
  if marked then
    return marked
  end
  local file = vim.fs.normalize(name)
  if file:lower():sub(1, #cwd + 1) == cwd:lower() .. "/" then
    return cwd
  end
  return vim.fs.dirname(file)
end

local function unwatch()
  if watcher then
    watcher:close()
    settle_timer:close()
    watcher, settle_timer, watched = nil, nil, nil
  end
end

local function watch()
  local dir = store.dir()
  if watcher and watched == dir then
    return
  end
  unwatch()
  vim.fn.mkdir(dir, "p")
  watcher = assert(vim.uv.new_fs_event())
  settle_timer = assert(vim.uv.new_timer())
  watched = dir
  watcher:start(dir, {}, function(_, name)
    changed[name or ""] = true
    settle_timer:start(150, 0, vim.schedule_wrap(on_change))
  end)
end

-- The folder watched from now on, or with false no longer, unless a trace is
-- shown. Started with the editor's screen: an editor with none, as one run
-- for a check, watches nothing.
function M.lookout(on)
  lookout = on ~= false
  if lookout then
    watch()
  elseif not state.path then
    unwatch()
  end
end

-- For the checks: the folder watched, or nil.
function M.watching()
  return watched
end

-- Shows the trace in `path`, or the newest; `follow` keeps to the newest as
-- new ones are written. False when there is no trace to show.
function M.open(path, follow)
  state.project = M.project()
  if not path then
    local newest = store.files(state.project)[1]
    path = newest and newest.path
    follow = true
  end
  if not path then
    -- Watched all the same, so the first trace written is shown once it
    -- comes: the panel opened before any said so, and stayed empty.
    state.follow = true
    watch()
    return false
  end
  local other = path ~= state.path
  state.path, state.follow, state.put_away = vim.fs.normalize(path), follow ~= false, nil
  if other then
    state.current = nil
  end
  read_again()
  watch()
  return true
end

-- The trace put away: nothing drawn in the code, the panel closed, and the
-- folder no longer watched, unless it is from the start. A trace written
-- after is shown, but not the one put away as it is written on.
function M.close()
  if not lookout then
    unwatch()
  end
  state.put_away = state.path
  state.follow = true
  state.path, state.trace, state.rows, state.current, state.located = nil, nil, {}, nil, {}
  decorate_all()
  panel().close()
end

-- Whether the notes show in the code (<leader>uR): put away, the code reads as
-- it is, the number of each step left in the sign column to say where the
-- steps are, as the notes of the pins are put away (<leader>uN).
function M.notes_shown()
  return state.notes
end

function M.show_notes(on)
  state.notes = on
  decorate_all()
end

-- Whether every step shows its note, not only the one chosen (N in the panel).
function M.all_notes_shown()
  return state.all_notes
end

function M.show_all_notes(on)
  state.all_notes = on
  decorate_all()
end

local function index_of(id)
  for index, row in ipairs(state.rows) do
    if row.step.id == id then
      return index
    end
  end
end

-- The line the function a step is in starts on, the line of its name; nil
-- where it is not known, as outside C.
function M.function_line(step)
  local kind = vim.filetype.match({ filename = step.file })
  if kind ~= "c" and kind ~= "cpp" then
    return nil
  end
  local outline = require("taka.lib.c_outline")
  local body = outline.enclosing(outline.read(vim.fs.normalize(step.file)), M.where(step).line)
  return body and body.kind == "function" and body.line or nil
end

-- A step shown in `win`, the cursor on its line, and made the one chosen:
-- its line tinted and the panel's cursor on its row. With `go` the cursor
-- goes to that window too, and the place it leaves is kept on the jump list.
-- With `at_function`, from the heading of its function in the panel, the
-- cursor is put on the line of the function's name instead: the heading
-- names the function, and showing the step under it there gave the heading
-- and the step the same place.
function M.show(row, win, go, at_function)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  state.current = row.step.id
  state.on_function = at_function or false
  if not vim.uv.fs_stat(row.step.file) then
    panel().focus(row.step.id)
    return vim.notify(("Step %d: %s is not there"):format(row.number, row.step.file), vim.log.levels.WARN)
  end
  local buf = vim.fn.bufadd(row.step.file)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if go then
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! m'")
    end)
  end
  vim.api.nvim_win_set_buf(win, buf)
  local line = M.locate(buf, row.step)
  if at_function then
    line = M.function_line(row.step) or line
  end
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! ^zz")
  end)
  decorate_all()
  panel().focus(row.step.id)
  if go then
    vim.api.nvim_set_current_win(win)
  end
end

-- The next step after the one chosen, or the one before with a negative
-- `direction`, in the order of the panel, shown in the current window.
function M.step(direction)
  if not state.trace then
    if not M.open() then
      return vim.notify("No trace to follow (" .. store.dir() .. ")", vim.log.levels.WARN)
    end
  end
  if #state.rows == 0 then
    return vim.notify("The trace has no steps yet", vim.log.levels.WARN)
  end
  local index = index_of(state.current)
  if not index then
    index = direction > 0 and 1 or #state.rows
  else
    index = index + direction
  end
  local row = state.rows[index]
  if not row then
    return vim.notify(direction > 0 and "The last step" or "The first step")
  end
  M.show(row, vim.api.nvim_get_current_win(), true)
end

-- The panel, showing the newest trace when none is shown yet.
function M.toggle_panel()
  if not state.trace then
    M.open()
  end
  panel().toggle()
end

-- A step as it is handed to whoever wrote the trace, to ask about it: the
-- trace, the step's number and title, and its place, under the trace's root
-- where it is, as the trace wrote it.
-- A step's place as "file:line", the file under the trace's root where it is.
local function place(step)
  local file = step.file
  local root = state.trace and state.trace.root
  if root and file:lower():sub(1, #root + 1) == root:lower() .. "/" then
    file = file:sub(#root + 2)
  end
  return ("%s:%d"):format(file, M.where(step).line)
end

function M.reference(row)
  return ('Trace "%s" step %d/%d: %s (%s)'):format(
    vim.fn.fnamemodify(state.path or "", ":t:r"),
    row.number,
    #state.rows,
    row.step.title,
    place(row.step)
  )
end

-- The whole trace as Markdown, to answer from or keep: its title, the answer
-- where a step gives one, then every step in order, each with its place and
-- note, a branch indented under the step it comes from. A step marked as a
-- cause, a suspect or an answer says so, and one the reader has edited too, so
-- what was not checked is not passed on as fact.
function M.report()
  if not state.trace then
    return ""
  end
  local out = {
    "# " .. state.trace.title,
    "",
    ('Trace "%s"'):format(vim.fn.fnamemodify(state.path or "", ":t:r")),
    "",
  }
  local answers = vim.tbl_filter(function(row)
    return row.step.kind == "answer"
  end, state.rows)
  if #answers > 0 then
    out[#out + 1] = "## Answer"
    out[#out + 1] = ""
    for _, row in ipairs(answers) do
      vim.list_extend(out, vim.split(row.step.note ~= "" and row.step.note or row.step.title, "\n"))
      out[#out + 1] = ("(step %d, `%s`)"):format(row.number, place(row.step))
      out[#out + 1] = ""
    end
  end
  out[#out + 1] = "## Steps"
  out[#out + 1] = ""
  for _, row in ipairs(state.rows) do
    local indent = string.rep("   ", row.depth)
    local tags = {}
    if row.step.kind ~= "" then
      tags[#tags + 1] = "[" .. row.step.kind .. "]"
    end
    if row.step.edited then
      tags[#tags + 1] = "[edited]"
    end
    if M.where(row.step).lost then
      tags[#tags + 1] = "[line not found]"
    end
    -- The function each step is in, so the reader follows a call and its
    -- return as the panel shows them.
    local func = M.function_of(row.step)
    out[#out + 1] = ("%s%d. **%s** `%s`%s%s"):format(
      indent,
      row.number,
      row.step.title,
      place(row.step),
      func ~= "" and (" in `" .. func .. "()`") or "",
      #tags > 0 and (" " .. table.concat(tags, " ")) or ""
    )
    if row.step.note ~= "" then
      for _, line in ipairs(vim.split(row.step.note, "\n")) do
        out[#out + 1] = line ~= "" and (indent .. "   " .. line) or ""
      end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- A step's note in a small window by the cursor, as K shows the documentation
-- of a name: read from the panel without the notes in the code, which may be
-- put away (<leader>uR). It closes once the cursor moves, as a hover does.
-- The note is shown as it was written, not as Markdown: a note on C is full of
-- `*p` and `a_b`, which Markdown took for emphasis and dropped.
function M.hover(row)
  local lines = { ("%d. %s"):format(row.number, row.step.title) }
  local tags = {}
  if row.step.kind ~= "" then
    tags[#tags + 1] = "[" .. row.step.kind .. "]"
  end
  if row.step.edited then
    tags[#tags + 1] = "[edited]"
  end
  if M.where(row.step).lost then
    tags[#tags + 1] = "[line not found]"
  end
  if #tags > 0 then
    lines[1] = lines[1] .. " " .. table.concat(tags, " ")
  end
  if row.step.note ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(row.step.note, "\n"))
  end
  lines[#lines + 1] = ""
  -- The function too: in the panel it heads a run of steps, often out of
  -- sight above the step, and a name too long for the panel is cut short.
  local func = M.function_of(row.step)
  lines[#lines + 1] = place(row.step) .. (func ~= "" and ("  " .. func .. "()") or "")
  local buf, win = vim.lsp.util.open_floating_preview(lines, "", {
    border = "rounded",
    focus_id = "trace_note",
    max_width = 80,
    close_events = { "CursorMoved", "BufLeave", "WinLeave" },
  })
  -- The title in the colour of the step's kind, the place dimmed.
  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, { end_col = #lines[1], hl_group = M.kind_colour(row.step) })
  vim.api.nvim_buf_set_extmark(buf, namespace, #lines - 1, 0, { end_col = #lines[#lines], hl_group = "Comment" })
  return buf, win
end

-- The whole trace copied as Markdown (Y in the panel).
function M.yank_report()
  if not state.trace then
    return vim.notify("No trace shown (<leader>ja shows one)", vim.log.levels.WARN)
  end
  local text = M.report()
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify(("Copied the trace as Markdown (%d steps)"):format(#state.rows))
end

-- Steps copied to the clipboard and to the unnamed register, a line each.
function M.yank(rows)
  local text = table.concat(vim.tbl_map(M.reference, rows), "\n")
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify(#rows == 1 and ("Copied: " .. text) or ("Copied %d steps"):format(#rows))
end

-- The title and the note of a step changed by the reader, in a window of its
-- own: the title on the first line and the note below a blank line, in a
-- buffer edited as any other, since a note runs over lines that a prompt of
-- one line would not hold. :w keeps the change, writing it to the trace's
-- file, and closes the window; q closes it, asking first when there is a
-- change to lose.
function M.edit(row)
  if not (row and state.path) then
    return
  end
  local path, id = state.path, row.step.id
  local name = ("trace://%s/%s"):format(vim.fn.fnamemodify(path, ":t:r"), id)
  -- The step is being edited already, in a window left open behind: that
  -- window is gone back to, with what was typed in it, as a second buffer of
  -- the same name cannot be made.
  local open = vim.iter(vim.api.nvim_list_bufs()):find(function(other)
    return vim.api.nvim_buf_get_name(other) == name
  end)
  if open then
    local shown = vim.fn.win_findbuf(open)[1]
    if shown then
      return vim.api.nvim_set_current_win(shown)
    end
    vim.api.nvim_buf_delete(open, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, name)
  local lines = { row.step.title, "" }
  vim.list_extend(lines, vim.split(row.step.note, "\n", { plain = true }))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "markdown"
  local width = math.min(90, vim.o.columns - 8)
  local height = math.min(math.max(#lines + 2, 8), math.floor(vim.o.lines * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = (" Step %d: title, then the note  (:w keeps it, q closes) "):format(row.number),
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local title = vim.trim(text[1] or "")
      local note = vim.trim(table.concat(vim.list_slice(text, 2), "\n"))
      if not store.edit_step(path, id, title ~= "" and title or row.step.title, note) then
        return vim.notify("The step is no longer in the trace", vim.log.levels.WARN)
      end
      vim.bo[buf].modified = false
      -- Closed once the command is done: closed here, the :q of :wq, :x or
      -- ZZ went on to the window behind, and quit the editor when it was the
      -- last one.
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end)
      -- The step edited is the one chosen, so its card shows what was written.
      if state.path == path then
        state.current = id
        read_again()
      end
    end,
  })
  vim.keymap.set("n", "q", function()
    if vim.bo[buf].modified and vim.fn.confirm("Leave the change?", "&Leave\n&Keep editing", 2) ~= 1 then
      return
    end
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true, desc = "Close, the change not kept" })
  vim.api.nvim_win_set_cursor(win, { math.min(3, #lines), 0 })
end

-- The step on the cursor's line edited, or else the step chosen (<leader>jn).
function M.edit_here()
  if not state.trace then
    return vim.notify("No trace shown (<leader>ja shows one)", vim.log.levels.WARN)
  end
  local name = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, row in ipairs(state.rows) do
    local found = state.located[row.step.id]
    if found and found.line == line and same_file(row.step.file, name) then
      return M.edit(row)
    end
  end
  local index = index_of(state.current)
  if not index then
    return vim.notify("No step on this line", vim.log.levels.WARN)
  end
  M.edit(state.rows[index])
end

-- The stored traces, the newest first, in a list as the other lists are:
-- Enter shows one in the panel, and it stays shown when newer ones are
-- written; <C-x>, or dd in the list, deletes the one under the cursor or the
-- ones marked with Tab. A trace is a file and gone once deleted, unlike a pin
-- or a buffer, so the list asks first.
--
-- The list holds the current project's traces; <A-a> shows those of every
-- project, and again those of this one. With none in this project it starts
-- on every project's.
function M.pick()
  if #store.files() == 0 then
    return vim.notify("No traces yet: they are read from " .. store.dir(), vim.log.levels.WARN)
  end
  local project = M.project()
  local everywhere = #store.files(project) == 0
  -- The traces of other projects are out of the list, not gone: their number
  -- is in the title, as a trace looked for and not seen there (its root
  -- written wrongly, or made for another checkout) was taken for one never
  -- written, and another was opened in its place.
  local function title()
    if everywhere then
      return "Traces (every project)"
    end
    local more = #store.files() - #store.files(project)
    local others = more > 0 and (" · %d more in other projects (<A-a>)"):format(more) or ""
    return ("Traces (%s)%s"):format(vim.fs.basename(project), others)
  end
  Snacks.picker({
    source = "trace_files",
    title = title(),
    finder = function()
      local items = {}
      for _, file in ipairs(store.files(not everywhere and project or nil)) do
        local trace = store.read(file.path)
        items[#items + 1] = {
          text = trace.title .. " " .. vim.fs.basename(file.path),
          path = file.path,
          title = trace.title,
          steps = #trace.steps,
          mtime = file.mtime,
        }
      end
      return items
    end,
    format = function(item)
      return {
        { item.path == state.path and "● " or "  ", "TraceStep" },
        { item.title },
        -- The name of a trace, its file's, is what it is asked about by: the
        -- title says what it is, the name which file it is.
        {
          ("  %s · %d steps · %s"):format(
            vim.fn.fnamemodify(item.path, ":t:r"),
            item.steps,
            os.date("%m-%d %H:%M", math.floor(item.mtime))
          ),
          "Comment",
        },
      }
    end,
    layout = { preset = "select" },
    -- The trace chosen is shown once the list has closed: its windows go on
    -- the next tick, and a panel made over them meanwhile met a resize of
    -- snacks on a window half closed, an error on a slow screen.
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          M.open(item.path, false)
          panel().open()
        end)
      end
    end,
    actions = {
      -- The traces marked with Tab, or the one under the cursor, copied by
      -- name, as a step is copied in the panel, to ask about them.
      trace_name = function(picker)
        local names = vim.tbl_map(function(item)
          return ('Trace "%s"'):format(vim.fn.fnamemodify(item.path, ":t:r"))
        end, picker:selected({ fallback = true }))
        picker.list:set_selected()
        if #names > 0 then
          local text = table.concat(names, "\n")
          vim.fn.setreg('"', text)
          pcall(vim.fn.setreg, "+", text)
          vim.notify("Copied: " .. table.concat(names, ", "))
        end
      end,
      trace_everywhere = function(picker)
        everywhere = not everywhere
        picker.title = title()
        picker:update_titles()
        picker.list:set_target()
        picker:find()
      end,
      trace_delete = function(picker)
        local items = picker:selected({ fallback = true })
        if #items == 0 then
          return
        end
        local question = #items == 1 and ('Delete the trace "%s"?'):format(items[1].title)
          or ("Delete %d traces?"):format(#items)
        if vim.fn.confirm(question, "&Delete\n&Keep", 2) ~= 1 then
          return
        end
        for _, item in ipairs(items) do
          os.remove(item.path)
          if item.path == state.path then
            M.close()
          end
        end
        picker.list:set_selected()
        picker.list:set_target()
        picker:find()
      end,
    },
    win = {
      input = {
        keys = {
          ["<c-x>"] = { "trace_delete", mode = { "n", "i" }, desc = "Delete trace" },
          ["<c-y>"] = { "trace_name", mode = { "n", "i" }, desc = "Copy the name of the trace" },
          ["<a-a>"] = { "trace_everywhere", mode = { "n", "i" }, desc = "Traces of every project, or this one" },
        },
      },
      list = {
        keys = {
          ["dd"] = { "trace_delete", desc = "Delete the trace (Tab marks several)" },
          ["y"] = { "trace_name", desc = "Copy the name of the trace (Tab marks several)" },
          ["<a-a>"] = { "trace_everywhere", desc = "Traces of every project, or this one" },
        },
      },
    },
  })
end

-- A trace file checked the way it is read here, so whoever writes one can
-- check it before handing it on: what could not be read, and for each step
-- whether its file is there and its text is on the line it names, else where
-- it is. The trace file is `path`, or the newest. The report as lines, the
-- first one a summary, and the number of problems.
function M.check(path)
  if not path or path == "" then
    path = (store.files()[1] or {}).path
  else
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  end
  if not path or not vim.uv.fs_stat(path) then
    return { "No trace file: " .. tostring(path) }, 1
  end
  local trace = store.read(path)
  local problems = {}
  for _, found in ipairs(trace.problems) do
    problems[#problems + 1] =
      { line = found.line or 0, text = ("line %s: %s"):format(found.line or "?", found.message) }
  end
  local files = {}
  for _, row in ipairs(store.outline(trace)) do
    local step = row.step
    local function problem(message)
      problems[#problems + 1] = {
        line = step.source or 0,
        text = ("line %s, step %d (%s:%d): %s"):format(
          step.source or "?",
          row.number,
          vim.fs.basename(step.file),
          step.line,
          message
        ),
      }
    end
    if files[step.file] == nil then
      -- As the file reads when opened: a step's text is what the editor shows.
      files[step.file] = vim.uv.fs_stat(step.file)
          and (require("taka.lib.legacy_text").lines(vim.fn.readfile(step.file)))
        or false
    end
    local lines = files[step.file]
    if not lines then
      problem("the file is not there")
    elseif step.line > #lines then
      problem(("the file has %d lines"):format(#lines))
    elseif step.text == "" then
      problem("no text, so the step cannot be found again once the code moves")
    else
      local line, found = M.locate_in(lines, step)
      if not found then
        problem(("the text is not in the file: %q"):format(step.text))
      elseif line ~= step.line then
        problem(("the text is on line %d, not on line %d"):format(line, step.line))
      end
    end
  end
  -- A trace is listed by its root. One whose root holds none of the files
  -- its steps are in passes every check above when the steps give whole
  -- paths, and is then not seen in the project it is about.
  local root, inside = trace.root:lower():gsub("/+$", "") .. "/", #trace.steps == 0
  for _, step in ipairs(trace.steps) do
    inside = inside or step.file:lower():sub(1, #root) == root
  end
  if trace.root_given and not inside then
    problems[#problems + 1] = {
      line = 0,
      text = ("the root %s holds none of the steps' files: the trace is listed there, not in their project"):format(
        trace.root
      ),
    }
  end
  table.sort(problems, function(a, b)
    return a.line < b.line
  end)
  local report = {
    ("%s: %d steps, %d problems"):format(vim.fs.basename(path), #trace.steps, #problems),
  }
  for _, found in ipairs(problems) do
    report[#report + 1] = found.text
  end
  -- Whether an editor open now reads the project the trace is about: one
  -- that does not shows nothing of it. Told, not counted as a problem: a
  -- trace may be meant for a project opened later.
  local open = editors.list()
  if trace.root_given and #open > 0 then
    local reads = false
    for _, editor in ipairs(open) do
      reads = reads or store.belongs(trace.root, editor.project)
    end
    if not reads then
      local projects = vim.tbl_map(function(editor)
        return editor.project
      end, open)
      report[#report + 1] = ("note: no editor open has %s; they have %s"):format(
        trace.root,
        table.concat(projects, ", ")
      )
    end
  end
  return report, #problems
end

-- The check run headless by whoever writes a trace, the report on standard
-- output and the number of problems as the exit code:
--   nvim --headless -c "lua require('taka.trace').check_and_exit([[file]])"
function M.check_and_exit(path)
  local report, count = M.check(path)
  io.stdout:write(table.concat(report, "\n") .. "\n")
  vim.cmd(count == 0 and "qa!" or ("cquit " .. math.min(count, 99)))
end

vim.api.nvim_create_user_command("TraceCheck", function(opts)
  local report, count = M.check(opts.args)
  vim.notify(table.concat(report, "\n"), count == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
end, { nargs = "?", complete = "file", desc = "Check a trace file: the one given, or the newest" })

M.reload = read_again

local group = vim.api.nvim_create_augroup("config_trace", { clear = true })
-- A file read again (:edit) has its project looked for again, as when a
-- .git or a GTAGS has been made above it since.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(event)
    marks[vim.api.nvim_buf_get_name(event.buf)] = nil
  end,
})
-- Read on VeryLazy, after the screen has come: then watched at once.
if #vim.api.nvim_list_uis() > 0 then
  M.lookout(true)
else
  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    once = true,
    callback = function()
      M.lookout(true)
    end,
  })
end
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(event)
    -- A file read for the first time may find a step on another line than
    -- the one written, which the panel then shows.
    if state.trace and M.decorate(event.buf) then
      panel().refresh()
    end
  end,
})
-- A step made the one chosen, its card opened where it is, or with nil none:
-- what a click on a note does, which leaves the cursor and the view alone,
-- where showing a step from the panel moves the window to it.
function M.choose(row)
  state.current = row and row.step.id or nil
  decorate_all()
  if row then
    panel().focus(row.step.id)
  end
end

-- A click on the lines of a note opens its card, or closes the card open. The
-- lines are no lines of the buffer and take no click of their own: Neovim puts
-- the cursor on the line under them and tells of that line, but of the row
-- clicked too, which is above the line's own row. `mouse` is what
-- getmousepos() tells. True when the click was on a note.
function M.clicked(mouse)
  if not state.trace or mouse.winid == 0 or mouse.line == 0 then
    return false
  end
  local own = vim.fn.screenpos(mouse.winid, mouse.line, 1).row
  if own == 0 or mouse.screenrow >= own then
    return false
  end
  -- Two steps on one line stack their notes over it, the first made on top:
  -- the row clicked, counted from the top of the stack, says whose note it is.
  local stack = (state.stacks[vim.api.nvim_win_get_buf(mouse.winid)] or {})[mouse.line] or {}
  local total = 0
  for _, note in ipairs(stack) do
    total = total + note.height
  end
  local from = own - total
  if mouse.screenrow < from then
    return false
  end
  for _, note in ipairs(stack) do
    if mouse.screenrow < from + note.height then
      M.choose(note.row.step.id ~= state.current and note.row or nil)
      return true
    end
    from = from + note.height
  end
  return false
end

-- Clicks are watched, not mapped, so the left button keeps what is mapped to it
-- (the strip of a comparison, the panels) and nothing is held up.
local left_mouse = vim.keycode("<LeftMouse>")
vim.on_key(function(key, typed)
  if (typed ~= "" and typed or key) == left_mouse and state.trace then
    vim.schedule(function()
      M.clicked(vim.fn.getmousepos())
    end)
  end
end, namespace)

-- The notes are wrapped to the windows they show in, so again when one of
-- them changes its width, as it does when the panel opens beside it.
vim.api.nvim_create_autocmd({ "WinResized", "BufWinEnter" }, {
  group = group,
  callback = function()
    if state.trace then
      decorate_all()
    end
  end,
})

-- An edit of a file with steps in it finds them again, so the panel names the
-- lines they are on now: the cards move with the lines by themselves, but the
-- panel kept the line numbers they had before. Not while typing, when a step's
-- own line is half written and would show as not found, but once insert mode
-- is left or a change is made in normal mode, and once for a run of changes.
-- The panel is drawn again only when a step's line has changed.
local edited_buffers = {}
vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
  group = group,
  callback = function(event)
    local buf = event.buf
    if not state.trace or edited_buffers[buf] then
      return
    end
    edited_buffers[buf] = true
    vim.defer_fn(function()
      edited_buffers[buf] = nil
      if state.trace and vim.api.nvim_buf_is_valid(buf) and M.decorate(buf) then
        panel().refresh()
      end
    end, 200)
  end,
})

vim.api.nvim_create_user_command("Trace", function(opts)
  if opts.args == "" then
    return M.pick()
  end
  if M.open(vim.fn.fnamemodify(opts.args, ":p"), false) then
    panel().open()
  end
end, { nargs = "?", complete = "file", desc = "Show a trace: the file given, or one chosen" })

return M

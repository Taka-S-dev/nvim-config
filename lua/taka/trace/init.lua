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
--                    does with <leader>uR
--   in the panel     the steps as a tree on the right (<leader>ja), each
--                    under the step it came from; moving through the rows
--                    shows each step in the code beside it
--
-- ]n and [n go to the next and the previous step from the code. The file is
-- read again whenever it changes, so a trace grows on the screen while it is
-- written, and while the newest trace is followed a new one replaces it.
local M = {}

local store = require("taka.trace.store")

local namespace = vim.api.nvim_create_namespace("config_trace")

-- The trace shown: the file, the trace read from it and its rows in order,
-- the step chosen last, whether the newest file is followed (not when one was
-- picked) and whether every step shows its note in the code, not only the
-- step chosen.
local state = { path = nil, trace = nil, rows = {}, current = nil, follow = true, all_notes = false }

-- The colour of a step goes by its kind, from the diagnostics, which every
-- scheme sets: a cause in the colour of an error, a suspect of a warning, the
-- rest of information. The note is in italics in the colour of information,
-- whatever the kind, set apart from the comments of the code it sits among.
-- The title of a step not chosen is dimmed as a comment is, and the line of
-- the step chosen last is tinted as a diagnostic's text is.
local function colours()
  local function set(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  set("TraceStep", { link = "DiagnosticInfo" })
  set("TraceCause", { link = "DiagnosticError" })
  set("TraceSuspect", { link = "DiagnosticWarn" })
  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  set("TraceNote", { fg = info.fg, italic = true })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  set("TraceTitle", { fg = normal.fg, bold = true })
  set("TraceTitleOther", { link = "Comment" })
  set("TraceCurrent", { link = "DiagnosticVirtualTextInfo" })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_trace_colours", { clear = true }),
  callback = colours,
})

local KIND_COLOUR = { cause = "TraceCause", suspect = "TraceSuspect" }

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

-- The lines above a step: its number and title, then its note, each behind a
-- bar in the colour of its kind and indented as the code line is, so the note
-- reads as a block that belongs to that line. A step other than the one chosen
-- keeps to its title, dimmed, unless every note is to show: notes on every
-- step of a function pushed its lines apart until the code was hard to read,
-- while a line each still says where the other steps are. Its note, left out,
-- is marked with an ellipsis.
local function note_lines(row, indent, width)
  local colour = M.kind_colour(row.step)
  local pad = string.rep(" ", indent)
  local full = state.all_notes or row.step.id == state.current
  local lines = {
    {
      { pad },
      { BAR .. " ", colour },
      { tostring(row.number) .. " ", colour },
      { row.step.title, full and "TraceTitle" or "TraceTitleOther" },
      { (not full and row.step.note ~= "") and " …" or "", "TraceTitleOther" },
    },
  }
  if full and row.step.note ~= "" then
    for _, text in ipairs(wrap(row.step.note, width)) do
      lines[#lines + 1] = { { pad }, { BAR .. "   ", colour }, { text, "TraceNote" } }
    end
  end
  return lines
end

local function same_file(a, b)
  return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower()
end

-- Draws the steps of the trace that are in one buffer.
function M.decorate(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or not state.trace then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  -- The text area of the narrowest window the buffer is in, which a line of
  -- the note must fit: one that does not is cut off at the edge, not wrapped.
  local room
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    room = math.min(room or math.huge, info.width - info.textoff)
  end
  room = room or vim.o.columns
  for _, row in ipairs(state.rows) do
    if same_file(row.step.file, name) then
      local line = math.min(row.step.line, count)
      local indent = vim.api.nvim_buf_call(buf, function()
        return vim.fn.indent(line)
      end)
      vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
        sign_text = row.number < 100 and ("%2d"):format(row.number) or "··",
        sign_hl_group = M.kind_colour(row.step),
        line_hl_group = row.step.id == state.current and "TraceCurrent" or nil,
        -- Past a hundred columns a line is hard to follow back to its start.
        virt_lines = note_lines(row, indent, math.max(20, math.min(100, room - indent - 6))),
        virt_lines_above = true,
        priority = 20,
      })
    end
  end
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
  decorate_all()
  panel().refresh()
end

-- The files are watched as a folder, through the system's notice of a change
-- and not by looking again and again: nothing runs while nothing is written.
-- A file written in pieces sends a notice per piece, so the reading waits for
-- them to stop. The watch starts with the first trace shown.
local watcher, settle_timer

local function on_change()
  if state.follow then
    local newest = store.files()[1]
    if newest and newest.path ~= state.path then
      state.path, state.current = newest.path, nil
      read_again()
      vim.notify(("Trace: %s (%d steps)"):format(state.trace.title, #state.rows))
      return
    end
  end
  read_again()
end

local function watch()
  if watcher then
    return
  end
  vim.fn.mkdir(store.dir(), "p")
  watcher = assert(vim.uv.new_fs_event())
  settle_timer = assert(vim.uv.new_timer())
  watcher:start(store.dir(), {}, function()
    settle_timer:start(150, 0, vim.schedule_wrap(on_change))
  end)
end

-- Shows the trace in `path`, or the newest; `follow` keeps to the newest as
-- new ones are written. False when there is no trace to show.
function M.open(path, follow)
  if not path then
    local newest = store.files()[1]
    path = newest and newest.path
    follow = true
  end
  if not path then
    return false
  end
  local changed = path ~= state.path
  state.path, state.follow = vim.fs.normalize(path), follow ~= false
  if changed then
    state.current = nil
  end
  read_again()
  watch()
  return true
end

-- The trace put away: nothing drawn in the code, the panel closed, and the
-- folder no longer watched.
function M.close()
  if watcher then
    watcher:close()
    settle_timer:close()
    watcher, settle_timer = nil, nil
  end
  state.path, state.trace, state.rows, state.current = nil, nil, {}, nil
  decorate_all()
  panel().close()
end

-- Whether every step shows its note, not only the one chosen (<leader>uR).
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

-- A step shown in `win`, the cursor on its line, and made the one chosen:
-- its line tinted and the panel's cursor on its row. With `go` the cursor
-- goes to that window too, and the place it leaves is kept on the jump list.
function M.show(row, win, go)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  state.current = row.step.id
  local buf = vim.fn.bufadd(row.step.file)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if go then
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! m'")
    end)
  end
  vim.api.nvim_win_set_buf(win, buf)
  local line = math.min(row.step.line, vim.api.nvim_buf_line_count(buf))
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

-- A trace chosen from the stored ones, the newest first, and shown in the
-- panel; it stays shown when newer ones are written.
function M.pick()
  local files = store.files()
  if #files == 0 then
    return vim.notify("No traces yet: they are read from " .. store.dir(), vim.log.levels.WARN)
  end
  local choices = {}
  for _, file in ipairs(files) do
    local trace = store.read(file.path)
    choices[#choices + 1] = {
      path = file.path,
      label = ("%s  (%d steps, %s)"):format(trace.title, #trace.steps, os.date("%m-%d %H:%M", math.floor(file.mtime))),
    }
  end
  vim.ui.select(choices, {
    prompt = "Trace",
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if choice then
      M.open(choice.path, false)
      panel().open()
    end
  end)
end

M.reload = read_again

local group = vim.api.nvim_create_augroup("config_trace", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(event)
    if state.trace then
      M.decorate(event.buf)
    end
  end,
})
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

vim.api.nvim_create_user_command("Trace", function(opts)
  if opts.args == "" then
    return M.pick()
  end
  if M.open(vim.fn.fnamemodify(opts.args, ":p"), false) then
    panel().open()
  end
end, { nargs = "?", complete = "file", desc = "Show a trace: the file given, or one chosen" })

return M

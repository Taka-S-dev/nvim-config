-- The trace panel (<leader>ja): the steps of the trace shown as a tree on the
-- right, laid out as the file tree and the pins panel are. Moving through the
-- rows, with the keys or a click, shows each step in the code beside it, the
-- cursor staying here; Enter or a double click goes there.
--
--   j, k, click      show the step in the code
--   Enter, double click
--                    go to the step
--   N                the notes of every step shown in the code, or only the
--                    note of the step chosen
--   r                edit the title and the note of the step
--   K                the step's note in a small window, as a hover
--   y, <C-y>         copy the step, or the steps marked with Tab, to ask
--                    about them
--   Y                copy the whole trace as Markdown, to answer from
--   R                read the trace again
--   t                another trace
--   X                put the trace away
local M = {}

local sidebar = require("taka.lib.sidebar")

local panel = {} ---@type { picker: table?, path: string?, opening: boolean? }

local WIDTH = 50

local function trace()
  return require("taka.trace")
end

local function is_open()
  return panel.picker ~= nil and not panel.picker.closed
end

-- A cause, a suspect and an answer carry a mark beside their number, so they
-- stand out in a long trace (cod-bug, cod-question and cod-check of the Nerd
-- Font).
local MARKS = { cause = " ", suspect = " ", answer = " " }

-- The line of a step is at the right edge. Its file is named only where it
-- is not the file of the row above: a trace stays in one file for steps on
-- end, and the same name on each row took the room of the titles, which were
-- cut short. The place is in one quiet colour: here the colours say the kind
-- of a step, and the colour of each folder, as the jump stack has them, mixed
-- with them (a folder in orange beside a cause in red). A step whose line is
-- not found has its place in the colour of a warning.
--
-- Where a step is in another function than the step above, a row of its own
-- names the function and its file, above the step: a trace goes from a
-- function into one it calls and back, and the steps of one function were not
-- told from those of the next. Named on the step's own row, beside its title
-- and file, the function took the room of the title and the three ran
-- together.
local function guides_of(row, look, header)
  if row.depth == 0 then
    return ""
  end
  local guides = ""
  for level = 2, #row.ancestors_last do
    guides = guides .. (row.ancestors_last[level] and "  " or look.vertical)
  end
  -- A heading stands between a step and the one it comes from: the line
  -- that joins them goes on through it.
  return guides .. (header and look.vertical or (row.last and look.last or look.middle))
end

local function row_text(row, short, look)
  local colour = trace().kind_colour(row.step)
  local where = trace().where(row.step)
  return {
    { guides_of(row, look, false), "SnacksPickerTree" },
    { ("%2d "):format(row.number), colour },
    { MARKS[row.step.kind] or "", colour },
    { row.step.title },
    -- A step whose title and note the reader has edited carries a mark.
    { row.step.edited and (" " .. "") or "", "TraceEdited" },
    {
      col = 0,
      virt_text = {
        { " " },
        { short and "" or vim.fs.basename(row.step.file), where.lost and "TraceLost" or "TraceFile" },
        { ":" .. where.line, where.lost and "TraceLost" or "Comment" },
        { " " },
      },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    },
  }
end

-- The heading of the steps in one function: its name, and its file at the
-- right. A name too long for the row is cut short, the file kept.
local function heading_text(item, look, room)
  local guides = guides_of(item.row, look, true)
  local file = vim.fs.basename(item.row.step.file)
  local width = vim.fn.strdisplaywidth
  local name = item.func .. "()"
  local fits = (room or WIDTH - 2) - width(guides) - width(file) - 4
  if width(name) > fits then
    name = vim.fn.strcharpart(name, 0, math.max(fits - 1, 4)) .. "…"
  end
  return {
    { guides, "SnacksPickerTree" },
    { name, "TraceFunction" },
    {
      col = 0,
      virt_text = { { " " }, { file, "TraceFile" }, { " " } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    },
  }
end

-- The rows of the panel: each step, and a heading above the first step of
-- each run of steps in one function. A heading carries the step below it, so
-- what is done on it, a press of K or of Enter, is done to that step.
local function build_items()
  local items, file_above, func_above = {}, nil, nil
  for _, row in ipairs(trace().state().rows) do
    local func = trace().function_of(row.step)
    local same_file = file_above ~= nil and file_above:lower() == row.step.file:lower()
    local sort = ("%06d"):format(row.number)
    if func ~= "" and not (same_file and func == func_above) then
      items[#items + 1] = {
        header = true,
        text = func .. " " .. vim.fs.basename(row.step.file),
        row = row,
        func = func,
        sort = sort .. "0",
      }
      -- The heading names the file.
      same_file = true
    end
    items[#items + 1] = {
      text = table.concat({ row.step.title, row.step.note, vim.fs.basename(row.step.file), func }, " "),
      row = row,
      func = func,
      same_file = same_file,
      sort = sort .. "1",
    }
    file_above, func_above = row.step.file, func
  end
  return items
end

-- The text of a row as drawn: a heading, or a step.
local function item_text(item, searching, look, room)
  if item.header then
    return heading_text(item, look, room)
  end
  return row_text(item.row, item.same_file and not searching, look)
end

-- The window the steps are shown in: the one the panel was opened from, or
-- else any window with a file in it.
local function code_window()
  local main = is_open() and panel.picker.main
  if main and vim.api.nvim_win_is_valid(main) and vim.api.nvim_win_get_config(main).relative == "" then
    return main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "" and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

-- The row of the panel a step is on, headings counted; with `header`, the
-- row of the heading above it, where it has one.
local function number_of(id, header)
  local heading
  for index, item in ipairs(build_items()) do
    if item.row.step.id == id then
      if item.header then
        heading = index
      else
        return header and heading or index
      end
    end
  end
end

local function title()
  local state = trace().state()
  if not state.trace then
    return "Trace"
  end
  -- Cut at the end to fit the panel: snacks cuts a long title at its start,
  -- which lost the words that say what the trace is.
  local text = ("Trace: %s"):format(state.trace.title)
  local room = WIDTH - 8
  if vim.fn.strdisplaywidth(text) > room then
    while vim.fn.strdisplaywidth(text) > room - 1 do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    text = text .. "…"
  end
  return text
end

function M.open()
  if is_open() then
    local list = panel.picker.list.win.win
    local here = vim.api.nvim_win_is_valid(list)
      and vim.api.nvim_win_get_tabpage(list) == vim.api.nvim_get_current_tabpage()
    if here and panel.path == trace().state().path then
      return
    end
    -- The title is the trace's, set as the panel is made; and a panel in
    -- another tab page is made again in this one. The new one is made once
    -- the old one's windows are gone, on the next tick, as the list of traces
    -- does it.
    panel.picker:close()
    return vim.schedule(M.open)
  end
  local look = sidebar.tree_look()
  local state = trace().state()
  panel.path, panel.opening = state.path, true
  require("taka.lib.sidebar").make_room()
  panel.picker = Snacks.picker({
    source = "trace",
    title = title(),
    -- Open with no trace yet too: the panel is where it will show up.
    show_empty = true,
    finder = build_items,
    -- While a filter is typed the rows between are hidden, and each names its
    -- file.
    format = function(item, picker)
      local searching = picker and picker.input and not picker.input.filter:is_empty()
      local win = picker and picker.list and picker.list.win.win
      local room = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or nil
      return item_text(item, searching, look, room)
    end,
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "sort" } },
    focus = "list",
    auto_close = false,
    jump = { close = false },
    layout = sidebar.layout({ width = WIDTH }),
    on_close = function(picker)
      if panel.picker == picker then
        panel.picker = nil
      end
    end,
    -- The step under the cursor shown in the code, once the cursor has moved to
    -- another step than the one chosen: drawing the panel again puts the
    -- cursor on the chosen one, which needs no showing.
    on_change = function(_, item)
      if not item then
        return
      end
      local current = trace().state().current
      -- Opened again, the panel starts on its first row: the cursor is taken
      -- to the step chosen before instead, and the code is left as it is.
      if panel.opening then
        panel.opening = false
        if current and number_of(current) then
          return M.focus(current)
        end
      end
      -- On a heading the start of its function is shown, and the cursor stays
      -- on the heading. Moved on by the panel to the step, past the heading
      -- the way the cursor went, it lost its way when the panel was drawn
      -- again in between, as it is once a lookup of a call comes back. The
      -- heading and the step under it are one step, shown at two places.
      local header = item.header or false
      if item.row.step.id ~= current or header ~= trace().state().on_function then
        trace().show(item.row, code_window(), false, header)
      end
    end,
    confirm = function(_, item)
      if item then
        trace().show(item.row, code_window(), true, item.header or false)
      end
    end,
    actions = {
      trace_notes = function()
        trace().show_all_notes(not trace().all_notes_shown())
      end,
      trace_edit = function(_, item)
        if item then
          trace().edit(item.row)
        end
      end,
      trace_hover = function(_, item)
        if item then
          trace().hover(item.row)
        end
      end,
      trace_yank = function(picker)
        local rows, seen = {}, {}
        for _, item in ipairs(picker:selected({ fallback = true })) do
          if not seen[item.row] then
            seen[item.row] = true
            rows[#rows + 1] = item.row
          end
        end
        picker.list:set_selected()
        if #rows > 0 then
          trace().yank(rows)
        end
      end,
      trace_report = function()
        trace().yank_report()
      end,
      trace_reload = function()
        trace().reload()
      end,
      trace_pick = function()
        trace().pick()
      end,
      trace_close = function()
        trace().close()
      end,
    },
    win = {
      input = {
        keys = {
          ["<c-y>"] = { "trace_yank", mode = { "n", "i" }, desc = "Copy step" },
          ["<a-e>"] = { "trace_edit", mode = { "n", "i" }, desc = "Edit step" },
        },
      },
      list = {
        keys = {
          ["N"] = { "trace_notes", desc = "Every note, or only the chosen step's" },
          ["R"] = { "trace_reload", desc = "Read the trace again" },
          ["y"] = { "trace_yank", desc = "Copy the step (Tab marks several)" },
          ["Y"] = { "trace_report", desc = "Copy the whole trace as Markdown" },
          ["K"] = { "trace_hover", desc = "Show the note of the step" },
          ["r"] = { "trace_edit", desc = "Edit the title and the note" },
          ["t"] = { "trace_pick", desc = "Another trace" },
          ["X"] = { "trace_close", desc = "Put the trace away" },
        },
      },
    },
  })
  if not state.trace then
    vim.notify("No trace yet: it shows here once one is written to " .. require("taka.trace.store").dir())
  end
end

function M.close()
  if is_open() then
    panel.picker:close()
  end
end

function M.toggle()
  if sidebar.closes(panel.picker) then
    return
  end
  M.open()
end

local function wanted(id, header)
  return function(item)
    return (item.header or false) == (header or false) and item.row.step.id == id
  end
end

-- The rows read again, the cursor kept on the step chosen, or else where it
-- was. Another trace than the one shown makes the panel anew, for its title.
function M.refresh()
  if not is_open() then
    return
  end
  local state = trace().state()
  if panel.path ~= state.path then
    if state.path then
      return M.open()
    end
    return M.close()
  end
  local current = panel.picker:current()
  local id = state.current or (current and current.row.step.id)
  -- A cursor on the heading of the step stays on it.
  local on_heading = current and current.header and current.row.step.id == id
  sidebar.refresh(panel.picker, number_of(id, on_heading), wanted(id, on_heading))
end

-- The cursor of the panel put on a step.
function M.focus(id)
  if not is_open() then
    return
  end
  -- On the step, or on its heading: the cursor is left where it is.
  local current = panel.picker:current()
  if current and current.row.step.id == id then
    return
  end
  local number = number_of(id)
  if number then
    panel.picker.list:view(number)
  end
end

-- For the checks: the rows of the panel as text.
function M.lines()
  if not is_open() then
    return {}
  end
  local out = {}
  for _, item in ipairs(panel.picker:items()) do
    local parts = {}
    for _, part in ipairs(item_text(item, false, sidebar.tree_look(), 200)) do
      if part[1] then
        parts[#parts + 1] = part[1]
      elseif part.virt_text then
        local tail = {}
        for index = 2, #part.virt_text - 1 do
          tail[#tail + 1] = part.virt_text[index][1]
        end
        parts[#parts + 1] = "  @" .. table.concat(tail)
      end
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

function M.is_open()
  return is_open()
end

return M

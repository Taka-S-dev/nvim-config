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
--   Enter, l         on a heading, fold the steps of its function, with the
--                    calls it makes, or open them, as a folder of the file
--                    tree opens and closes
--   h                fold the function the cursor is in and go to its
--                    heading; on a folded heading, go to the one above
--   za, zM, zR       fold or open one, fold every function, open them all
local M = {}

local sidebar = require("taka.lib.sidebar")

-- `folded`: the headings folded in the trace shown, by the id of the step
-- each heads.
local panel = { folded = {} } ---@type { picker: table?, path: string?, opening: boolean?, folded: table }

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
--
-- A function the one above it calls is set in a step, its steps with it, so
-- the calls read as they nest: a call is taken as one only where the code
-- shows it (lua/taka/trace/calls.lua), and a function the trace comes back
-- to goes back to where it stood. A call made through a function the trace
-- does not go into names that function on the heading. One the trace goes to
-- with no call seen, a side path or a call through a pointer, stands at the
-- left, and what stood before is kept for the trace to come back to. Past a
-- few steps in, the rows would leave the titles no room. A heading is set by
-- the calls only, with none of the lines of the tree of steps: with them, a
-- heading over a step written as a branch stood as deep as a call, and named
-- a function the one above it did not call.
local MAX_DEPTH = 4

-- A line for each call the row is inside, as the guides of the indent are
-- drawn in the code: with blanks only, which function a deep row was in was
-- hard to follow up the panel. In the colour of the guides of the indent,
-- apart from the dimmer lines of the tree of steps.
local function indent(depth, look)
  return string.rep(look.vertical, math.min(depth or 0, MAX_DEPTH))
end

local function guides_of(row, look)
  if row.depth == 0 then
    return ""
  end
  local guides = ""
  for level = 2, #row.ancestors_last do
    guides = guides .. (row.ancestors_last[level] and "  " or look.vertical)
  end
  return guides .. (row.last and look.last or look.middle)
end

local function row_text(row, short, look, depth)
  local colour = trace().kind_colour(row.step)
  local where = trace().where(row.step)
  return {
    { indent(depth, look), "TraceCallGuide" },
    { guides_of(row, look), "SnacksPickerTree" },
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

-- The heading of the steps in one function: its name, the function it is
-- called through where there is one, and its file at the right. A name too
-- long for the row is cut short, the file kept.
--
-- One the trace goes to with no call seen says so, `← ?`: at the left it was
-- not told from the function the trace starts in, and read as another start.
-- One deeper than the rows go says how much deeper, `+2`, where it would
-- otherwise stand level with the one that calls it.
local function heading_text(item, look, room)
  local guides = indent(item.depth, look)
  local deeper = (item.depth or 0) - MAX_DEPTH
  local more = deeper > 0 and ("+" .. deeper .. " ") or ""
  local file = vim.fs.basename(item.row.step.file)
  local width = vim.fn.strdisplaywidth
  local name = item.func .. "()"
  local via = item.via and ("  ← " .. item.via .. "()") or item.unknown and "  ← ?" or ""
  local folded = item.hidden_steps and ("  ⋯ " .. item.hidden_steps) or ""
  -- Open or folded, as the folders of the file tree show it.
  local mark = panel.folded[item.row.step.id] and "▸ " or "▾ "
  local fits = (room or WIDTH - 2) - width(guides .. more .. mark) - width(file) - 4 - width(folded)
  if width(name .. via) > fits then
    via = ""
  end
  if width(name) > fits then
    name = vim.fn.strcharpart(name, 0, math.max(fits - 1, 4)) .. "…"
  end
  return {
    { guides, "TraceCallGuide" },
    { more, "Comment" },
    { mark, "TraceFolded" },
    { name, "TraceFunction" },
    { via, "Comment" },
    { folded, "TraceFolded" },
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
-- what is done on it, a press of K or y, is done to that step. Each
-- row has the depth of the calls its function is in.
local function build_items()
  local items, file_above, func_above = {}, nil, nil
  -- The functions called, the outermost first, down to the one the trace is
  -- in; and the depth of the rows being made.
  local stack, depth = {}, 0
  local function same(entry, func, file)
    return entry.func == func and entry.file:lower() == file:lower()
  end
  for _, row in ipairs(trace().state().rows) do
    local func = trace().function_of(row.step)
    local file = row.step.file
    local same_file = file_above ~= nil and file_above:lower() == file:lower()
    local sort = ("%06d"):format(row.number)
    if func == "" then
      depth = 0
    elseif not (same_file and func == func_above) then
      local back
      for index = #stack, 1, -1 do
        if same(stack[index], func, file) then
          back = index
          break
        end
      end
      local top = stack[#stack]
      local via = top and not back and require("taka.trace.calls").via(top.file, top.func, func, M.refresh_later)
      if back then
        for index = #stack, back + 1, -1 do
          stack[index] = nil
        end
        depth = back - 1
      elseif not top then
        stack[1], depth = { func = func, file = file }, 0
      elseif via then
        stack[#stack + 1] = { func = func, file = file }
        depth = #stack - 1
      else
        depth = 0
      end
      -- Coming back to a function, its steps go on at its depth under the
      -- heading it already has: a second heading of the same name read as a
      -- second call of it.
      if not back then
        items[#items + 1] = {
          header = true,
          text = func .. " " .. vim.fs.basename(file),
          row = row,
          func = func,
          via = via and via ~= "" and via or nil,
          -- No call seen, once nothing is left to look up.
          unknown = top ~= nil and via == false,
          depth = depth,
          sort = sort .. "0",
        }
      end
      -- The heading names the file: this one, or the one the function the
      -- trace comes back to already has.
      same_file = true
    end
    items[#items + 1] = {
      text = table.concat({ row.step.title, row.step.note, vim.fs.basename(file), func }, " "),
      row = row,
      func = func,
      depth = depth,
      same_file = same_file,
      sort = sort .. "1",
    }
    file_above, func_above = file, func
  end
  return items
end

-- The last row of what the heading at `index` of `items` holds: the steps
-- of its function and of the calls it makes, up to a heading as shallow as
-- it, or a step out of it.
local function block_end(items, index)
  local depth, last = items[index].depth, index
  for at = index + 1, #items do
    local item = items[at]
    if (item.header and item.depth <= depth) or item.depth < depth then
      break
    end
    last = at
  end
  return last
end

-- The rows shown, the ones a folded heading holds left out, and by the id of
-- each step left out, the id of the heading that holds it: the outermost
-- one folded, which is shown.
local function visible_items()
  local all, out, hidden = build_items(), {}, {}
  local at = 1
  while at <= #all do
    local item = all[at]
    out[#out + 1] = item
    if item.header and panel.folded[item.row.step.id] then
      local last, steps = block_end(all, at), 0
      for inside = at + 1, last do
        if not all[inside].header then
          steps = steps + 1
          hidden[all[inside].row.step.id] = item.row.step.id
        end
      end
      item.hidden_steps = steps
      at = last + 1
    else
      at = at + 1
    end
  end
  return out, hidden
end

-- The text of a row as drawn: a heading, or a step.
local function item_text(item, searching, look, room)
  if item.header then
    return heading_text(item, look, room)
  end
  return row_text(item.row, item.same_file and not searching, look, item.depth)
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

-- The panel drawn again once what a lookup of a call waited for is known.
function M.refresh_later()
  vim.schedule(function()
    M.refresh()
  end)
end

-- The row of the panel a step is on, headings counted; with `header`, the
-- row of the heading above it, where it has one. A step a fold holds is on
-- the row of the folded heading.
local function number_of(id, header)
  local items, hidden = visible_items()
  if hidden[id] then
    id, header = hidden[id], true
  end
  local heading
  for index, item in ipairs(items) do
    if item.row.step.id == id then
      if item.header then
        heading = index
        if header then
          return index
        end
      elseif not header then
        return index
      end
    end
  end
  return heading
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
  if panel.path ~= state.path then
    panel.folded = {}
  end
  panel.path, panel.opening = state.path, true
  require("taka.lib.sidebar").make_room()
  panel.picker = Snacks.picker({
    source = "trace",
    title = title(),
    -- Open with no trace yet too: the panel is where it will show up.
    show_empty = true,
    finder = function()
      return (visible_items())
    end,
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
    confirm = function(picker, item)
      if not item then
        return
      end
      if item.header then
        return M.toggle_fold(picker.list.cursor)
      end
      trace().show(item.row, code_window(), true)
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
      trace_fold = function(picker, item)
        if item then
          M.toggle_fold(picker.list.cursor)
        end
      end,
      trace_fold_all = function()
        M.fold_all(true)
      end,
      trace_fold_close = function(picker, item)
        if item then
          M.close_fold(picker.list.cursor)
        end
      end,
      trace_open_all = function()
        M.fold_all(false)
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
          ["l"] = { "confirm", desc = "Open or fold the function, or go to the step" },
          ["h"] = { "trace_fold_close", desc = "Fold the function and go to its heading" },
          ["za"] = { "trace_fold", desc = "Fold the steps of the function, or open them" },
          ["zM"] = { "trace_fold_all", desc = "Fold every function" },
          ["zR"] = { "trace_open_all", desc = "Open every function" },
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
  -- A cursor on the heading of the step stays on it, and one on a step a
  -- fold now holds goes to the folded heading.
  local on_heading = current and current.header and current.row.step.id == id
  local _, hidden = visible_items()
  if hidden[id] then
    id, on_heading = hidden[id], true
  end
  sidebar.refresh(panel.picker, number_of(id, on_heading), wanted(id, on_heading))
end

-- The heading the row at `index` is under, folded or not: the row itself
-- where it is one.
local function heading_at(items, index)
  for at = index, 1, -1 do
    if items[at].header and block_end(items, at) >= index then
      return items[at]
    end
  end
end

-- The steps under the heading the cursor is on, or under, folded, or opened
-- again.
function M.toggle_fold(index)
  if not is_open() then
    return
  end
  local items = panel.picker:items()
  local heading = items[index] and heading_at(items, index)
  if not heading then
    return
  end
  local id = heading.row.step.id
  panel.folded[id] = not panel.folded[id] or nil
  sidebar.refresh(panel.picker, number_of(id, true), wanted(id, true))
end

-- The function the row at `index` is in folded, and the cursor on its
-- heading; on a heading folded already, the cursor goes to the heading
-- above it, as h does on a folder of the file tree.
function M.close_fold(index)
  if not is_open() then
    return
  end
  local items = panel.picker:items()
  local item = items[index]
  local heading = item and heading_at(items, index)
  if not heading then
    return
  end
  local id = heading.row.step.id
  if heading == item and panel.folded[id] then
    local above = index > 1 and heading_at(items, index - 1)
    if above then
      sidebar.refresh(panel.picker, number_of(above.row.step.id, true), wanted(above.row.step.id, true))
    end
    return
  end
  panel.folded[id] = true
  sidebar.refresh(panel.picker, number_of(id, true), wanted(id, true))
end

-- Every function folded, or every one opened.
function M.fold_all(fold)
  if not is_open() then
    return
  end
  panel.folded = {}
  if fold then
    for _, item in ipairs(build_items()) do
      if item.header then
        panel.folded[item.row.step.id] = true
      end
    end
  end
  M.refresh()
end

-- The cursor of the panel put on a step.
function M.focus(id)
  if not is_open() then
    return
  end
  -- On the step, or on its heading: the cursor is left where it is. First:
  -- the step of a heading just folded is one its fold holds, and shown from
  -- the heading it opened the fold again.
  local current = panel.picker:current()
  if current and current.row.step.id == id then
    return
  end
  -- A step a fold holds, gone to from the code with ]n, opens the folds
  -- around it, as a jump into a fold opens it in Vim.
  local _, hidden = visible_items()
  if hidden[id] then
    while hidden[id] do
      panel.folded[hidden[id]] = nil
      _, hidden = visible_items()
    end
    return M.refresh()
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

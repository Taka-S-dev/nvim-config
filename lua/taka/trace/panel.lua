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

-- The place of a step takes the colour of its folder, so a step into another
-- module shows without reading the file names, as in the jump stack: the same
-- folder the same colour, the next folder reached the next colour, in turn.
local MODULE_COLOURS = { "String", "Constant", "Keyword", "Label", "DiagnosticHint" }
for index, link in ipairs(MODULE_COLOURS) do
  vim.api.nvim_set_hl(0, "TraceModule" .. index, { link = link, default = true })
end

-- A cause and a suspect carry a mark beside their number, so they stand out in
-- a long trace (cod-bug and cod-question of the Nerd Font).
local MARKS = { cause = " ", suspect = " " }

local function row_text(row, module, look)
  local guides = ""
  if row.depth > 0 then
    for level = 2, #row.ancestors_last do
      guides = guides .. (row.ancestors_last[level] and "  " or look.vertical)
    end
    guides = guides .. (row.last and look.last or look.middle)
  end
  local colour = trace().kind_colour(row.step)
  local place = ("%s:%d"):format(vim.fs.basename(row.step.file), row.step.line)
  return {
    { guides, "SnacksPickerTree" },
    { ("%2d "):format(row.number), colour },
    { MARKS[row.step.kind] or "", colour },
    { row.step.title },
    {
      col = 0,
      virt_text = {
        { " " },
        { place, "TraceModule" .. ((module - 1) % #MODULE_COLOURS + 1) },
        { " " },
      },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    },
  }
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

local function number_of(id)
  for _, row in ipairs(trace().state().rows) do
    if row.step.id == id then
      return row.number
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
    if panel.path == trace().state().path then
      return
    end
    -- The title is the trace's, set as the panel is made.
    panel.picker:close()
  end
  local look = sidebar.tree_look()
  local state = trace().state()
  panel.path, panel.opening = state.path, true
  panel.picker = Snacks.picker({
    source = "trace",
    title = title(),
    -- Open with no trace yet too: the panel is where it will show up.
    show_empty = true,
    finder = function()
      local items, modules = {}, {}
      for _, row in ipairs(trace().state().rows) do
        local folder = vim.fs.dirname(row.step.file):lower()
        modules[folder] = modules[folder] or (vim.tbl_count(modules) + 1)
        items[#items + 1] = {
          text = table.concat({ row.step.title, row.step.note, vim.fs.basename(row.step.file) }, " "),
          row = row,
          module = modules[folder],
          sort = ("%06d"):format(row.number),
        }
      end
      return items
    end,
    format = function(item)
      return row_text(item.row, item.module, look)
    end,
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "sort" } },
    focus = "list",
    auto_close = false,
    jump = { close = false },
    layout = sidebar.layout({ width = WIDTH }),
    on_close = function()
      panel.picker = nil
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
      if item.row.step.id ~= current then
        trace().show(item.row, code_window())
      end
    end,
    confirm = function(_, item)
      if item then
        trace().show(item.row, code_window(), true)
      end
    end,
    actions = {
      trace_notes = function()
        trace().show_all_notes(not trace().all_notes_shown())
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
      list = {
        keys = {
          ["N"] = "trace_notes",
          ["R"] = "trace_reload",
          ["t"] = "trace_pick",
          ["X"] = "trace_close",
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
  if is_open() then
    return M.close()
  end
  M.open()
end

local function wanted(id)
  return function(item)
    return item.row.step.id == id
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
  sidebar.refresh(panel.picker, number_of(id), wanted(id))
end

-- The cursor of the panel put on a step.
function M.focus(id)
  if not is_open() then
    return
  end
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
    for _, part in ipairs(row_text(item.row, item.module, sidebar.tree_look())) do
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

function M.is_open()
  return is_open()
end

return M

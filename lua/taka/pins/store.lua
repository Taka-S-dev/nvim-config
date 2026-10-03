-- Pins as stored: one file per project under Neovim's data directory, the
-- tree they make, the undo kept for the session, and where a pinned line is
-- now. Nothing here draws.

-- The directory a file's pins are kept under: the one holding GTAGS or .git
-- above it, else the cwd, and for a file that is not under the cwd either, its
-- own directory. A pin stores its path relative to this, so it has to be a
-- directory the file really is in.
local function project_root(file)
  local marked = file ~= "" and vim.fs.root(file, { "GTAGS", ".git" }) or nil
  if marked then
    return vim.fs.normalize(marked)
  end
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local path = vim.fs.normalize(file)
  if file == "" or path:lower():sub(1, #cwd + 1) == cwd:lower() .. "/" then
    return cwd
  end
  return vim.fs.dirname(path)
end

local function store_path(root)
  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "pins")
  vim.fn.mkdir(dir, "p")
  return vim.fs.joinpath(dir, vim.fn.sha256(root:lower()):sub(1, 16) .. ".json")
end

local function new_id(pins)
  local taken = {}
  for _, pin in ipairs(pins) do
    taken[pin.id or ""] = true
  end
  local number = #pins + 1
  while taken[tostring(number)] do
    number = number + 1
  end
  return tostring(number)
end

-- Words a function name found before lua/taka/lib/enclosing.lua could be, when
-- a declaration was wrapped in macros; a stored pin with one has no name.
local not_a_name = require("taka.lib.enclosing").not_a_name

-- The list as stored: a flat array whose order is the order among siblings,
-- each pin naming its parent. Files written before pins had ids are read as a
-- flat list.
local function load(root)
  local file = io.open(store_path(root), "r")
  if not file then
    return {}
  end
  local ok, data = pcall(vim.json.decode, file:read("*a"))
  file:close()
  local pins = ok and type(data) == "table" and data.pins or {}
  local known = {}
  for _, pin in ipairs(pins) do
    pin.id = pin.id or new_id(pins)
    known[pin.id] = true
    if not_a_name[pin.symbol or ""] then
      pin.symbol = ""
    end
  end
  for _, pin in ipairs(pins) do
    if pin.parent == vim.NIL or not known[pin.parent or ""] then
      pin.parent = nil
    end
  end
  return pins
end

local function save(root, pins)
  local file = assert(io.open(store_path(root), "w"))
  file:write(vim.json.encode({ root = root, pins = pins }))
  file:close()
end

-- Undo for the panel. Each change the reader makes keeps the list as it was
-- before it, per project and for the session; the stored line numbers that
-- follow an edit of the file are not changes of that kind and are left out.
local history = {}

local function remember(root)
  history[root] = history[root] or { undo = {}, redo = {} }
  local steps = history[root]
  steps.undo[#steps.undo + 1] = load(root)
  steps.redo = {}
  if #steps.undo > 100 then
    table.remove(steps.undo, 1)
  end
end

local function absolute(root, pin)
  return vim.fs.joinpath(root, pin.file)
end

local function index_of(pins, id)
  for index, pin in ipairs(pins) do
    if pin.id == id then
      return index
    end
  end
end

-- Depth first, siblings in stored order. Each row carries what the panel needs
-- to draw it: whether it is the last of its siblings, the same for each of its
-- ancestors, whether it has children, and whether a collapsed ancestor hides it.
local function outline(pins)
  local rows = {}
  local function visit(parent, depth, ancestors_last, hidden)
    local siblings = {}
    for index, pin in ipairs(pins) do
      if pin.parent == parent then
        siblings[#siblings + 1] = index
      end
    end
    for position, index in ipairs(siblings) do
      local pin = pins[index]
      local row = {
        pin = pin,
        depth = depth,
        index = index,
        last = position == #siblings,
        ancestors_last = ancestors_last,
        hidden = hidden,
      }
      rows[#rows + 1] = row
      local below = vim.list_extend({}, ancestors_last)
      below[#below + 1] = row.last
      local before = #rows
      visit(pin.id, depth + 1, below, hidden or pin.collapsed == true)
      row.has_children = #rows > before
    end
  end
  visit(nil, 0, {}, false)
  return rows
end

-- Where the pinned line is now: the recorded line if it still holds the
-- recorded text, else the nearest line that does.
local function locate(buf, pin)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if pin.text == "" or (lines[pin.line] and vim.trim(lines[pin.line]) == pin.text) then
    return math.min(pin.line, #lines), true
  end
  for distance = 1, #lines do
    for _, candidate in ipairs({ pin.line - distance, pin.line + distance }) do
      if lines[candidate] and vim.trim(lines[candidate]) == pin.text then
        return candidate, true
      end
    end
  end
  return math.max(1, math.min(pin.line, #lines)), false
end

-- The pins of a buffer with the line each is on now: { index, pin, line }.
local function pins_in(buf, root, pins)
  local here = vim.fs.normalize(vim.api.nvim_buf_get_name(buf)):lower()
  local found = {}
  for index, pin in ipairs(pins) do
    if vim.fs.normalize(absolute(root, pin)):lower() == here then
      local line, still_there = locate(buf, pin)
      found[#found + 1] = { index = index, pin = pin, line = line, moved = still_there and line ~= pin.line }
    end
  end
  return found
end

-- The list without one pin. The pins under it move out a level and take its
-- place among its siblings, so a note is never lost with its parent.
local function without(pins, id)
  local gone = pins[index_of(pins, id) or 0]
  if not gone then
    return pins
  end
  local kept, children = {}, {}
  for _, pin in ipairs(pins) do
    if pin.parent == gone.id then
      pin.parent = gone.parent
      children[#children + 1] = pin
    elseif pin ~= gone then
      kept[#kept + 1] = pin
    else
      kept[#kept + 1] = false
    end
  end
  local left = {}
  for _, pin in ipairs(kept) do
    if pin then
      left[#left + 1] = pin
    else
      vim.list_extend(left, children)
    end
  end
  return left
end

return {
  project_root = project_root,
  store_path = store_path,
  new_id = new_id,
  load = load,
  save = save,
  history = history,
  remember = remember,
  absolute = absolute,
  index_of = index_of,
  outline = outline,
  locate = locate,
  pins_in = pins_in,
  without = without,
}

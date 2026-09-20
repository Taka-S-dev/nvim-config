-- Pins: lines worth coming back to, each with a note, kept as a tree.
--
-- Reading a large tree means following a call several files deep and then
-- needing the place three jumps back. Marks hold 26 places and say nothing
-- about why; the jumplist holds every place, wanted or not. A pin is put down
-- on purpose, carries a note in the reader's own words, and is kept per project
-- across sessions.
--
--   <leader>jm  pin the current line; asks for the note, which may be empty.
--               A new pin always goes to the end of the list, at the top level.
--               On a line that is pinned already: edit its note or remove it
--   <leader>jM  find a pin: filter by note, function or file name, Enter jumps;
--               <A-e> edits the note and <A-d> removes the pin
--   <leader>jo  the panel, a sidebar on the right built like the file tree's, with a filter box on
--               top (/ or i goes to it) and the pins below:
--                 Enter  jump             r   edit the note
--                 K / J  move up / down   dd  remove
--                 > / <  make it a child of the pin above / move it out a level
--                 h / l  close / open the pins under it (za switches)
--                 u      undo, <C-r> redo: removing, moving, nesting, notes
--                 Tab    mark a pin; dd then removes all the marked ones,
--                        after asking (<C-a> marks every pin)
--                 q      close
--               Typing a filter keeps the tree and shows the matching pins,
--               closed ones included, under the pins they hang on; arranging
--               is off until the filter is cleared.
--
-- The panel draws the pins the way the file tree beside it is laid out: guide
-- lines, and a marker on every row so that one level lines up. A pin with pins
-- under it can be closed; what is closed is remembered.
--
-- A pin moves together with the pins under it. Removing a pin keeps the pins
-- under it and moves them out a level, so a note is never lost with its parent.
--
-- A pinned line shows a mark in the sign column and its note at the end of the
-- line. Pins are stored under Neovim's data directory, one file per project,
-- never in the source tree. A pin remembers the text of its line: when the file
-- has changed and the line has moved, the jump lands on the nearest line with
-- that text and the pin follows it.
local M = {}

local namespace = vim.api.nvim_create_namespace("config_pins")
local panel = { picker = nil, root = nil }

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

-- What treesitter hands back as a name when a declaration is wrapped in macros
-- and calling conventions, as in ms/applink.c: not a function name.
local not_a_name = {}
for word in ("void int char short long float double signed unsigned static const struct union enum"):gmatch("%S+") do
  not_a_name[word] = true
end

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

-- For the checks, which remove the files they leave behind.
M.store_path = store_path

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

-- The tree as the panel shows it, for the checks: "depth:note" per row.
function M.outline(root)
  return vim.tbl_map(function(row)
    return row.depth .. ":" .. row.pin.memo
  end, outline(load(root)))
end

-- The name of the function the cursor is in, where treesitter can tell.
local function enclosing_function()
  local ok, node = pcall(vim.treesitter.get_node)
  while ok and node do
    if node:type():find("function") then
      local found
      local function search(n, depth)
        if found or depth > 6 then
          return
        end
        if n:type() == "identifier" or n:type() == "field_identifier" then
          found = vim.treesitter.get_node_text(n, 0)
          return
        end
        for child in n:iter_children() do
          if child:type() ~= "compound_statement" and child:type() ~= "block" and child:type() ~= "parameter_list" then
            search(child, depth + 1)
          end
        end
      end
      local declarator = node:field("declarator")[1] or node:field("name")[1]
      if declarator then
        search(declarator, 0)
      end
      if found and not not_a_name[found] then
        return found
      end
    end
    node = node:parent()
  end
  return ""
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

-- Draws the marks of one buffer. A line that has moved since it was pinned,
-- through an edit here or a pull outside, is looked up by its text first, so
-- the mark is drawn where the line is and not where it was; the new line
-- number is stored.
function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local root = project_root(name)
  local pins = load(root)
  local moved = false
  for _, at in ipairs(pins_in(buf, root, pins)) do
    if at.moved then
      at.pin.line = at.line
      moved = true
    end
    vim.api.nvim_buf_set_extmark(buf, namespace, at.line - 1, 0, {
      sign_text = "●",
      sign_hl_group = "DiagnosticInfo",
      virt_text = at.pin.memo ~= "" and { { "  ● " .. at.pin.memo, "DiagnosticInfo" } } or nil,
      virt_text_pos = "eol",
    })
  end
  if moved then
    save(root, pins)
  end
end

-- The panel is laid out the way the file tree next to it is: the same guide
-- characters, read from snacks at draw time, and a marker of one width on every
-- row, so the notes of one level start in one column. The markers are one
-- family, the way a folder is one shape open and closed: a bookmark for a pin,
-- a stack of bookmarks for a pin with pins under it, in outline while they
-- show and filled while they are closed. They come from the Nerd Font the rest
-- of the UI already needs (md-bookmark_outline, md-bookmark_multiple_outline,
-- md-bookmark_multiple).
local markers = { leaf = "󰃃 ", open = "󰸖 ", closed = "󰸕 " }

local function tree_look()
  local tree = {}
  pcall(function()
    tree = Snacks.picker.config.get().icons.tree
  end)
  return {
    vertical = tree.vertical or "│ ",
    middle = tree.middle or "├╴",
    last = tree.last or "└╴",
  }
end

local function panel_is_open()
  return panel.picker ~= nil and not panel.picker.closed
end

local function is_searching(picker)
  return not picker.input.filter:is_empty()
end

-- One row of the panel as highlighted text. While a filter is typed, the pins
-- above a match are shown with it and everything counts as open.
local function row_text(row, look, searching)
  local pin = row.pin
  -- The pins at the top level carry no guide: there is no row above them for a
  -- line to come from, as the project's name is in the file tree. Below them
  -- the guides are the file tree's.
  local guides = ""
  if row.depth > 0 then
    for level = 2, #row.ancestors_last do
      guides = guides .. (row.ancestors_last[level] and "  " or look.vertical)
    end
    guides = guides .. (row.last and look.last or look.middle)
  end
  local closed = pin.collapsed and not searching
  local marker = row.has_children and (closed and markers.closed or markers.open) or markers.leaf
  local note = pin.memo ~= "" and pin.memo or pin.text
  local place = ("%s:%d"):format(vim.fs.basename(pin.file), pin.line)
  return {
    { guides, "SnacksPickerTree" },
    { marker, "DiagnosticInfo" },
    -- No highlight group for a note: "Normal" carries the background of the
    -- editing windows, which showed as a box on the sidebar and cut a hole in
    -- the line under the cursor.
    { note, pin.memo == "" and "Comment" or nil },
    -- The place is what a pin is for, so it sits at the right edge, where the
    -- file tree puts its git and diagnostic marks: whatever the width and
    -- however long the note, it is in view, and a note too long for the row
    -- loses its end to it. The function name has no room in a sidebar; it is
    -- in the list of <leader>jM and the filter still matches it.
    {
      col = 0,
      virt_text = { { " " }, { place, "Comment" }, { " " } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    },
  }
end

-- Reads the pins again and leaves the cursor on the pin with the given id, or
-- where it was. The list is emptied and filled again by the finder a moment
-- later, which takes the cursor back to the first row, and the callback find()
-- offers runs before the rows are there. So the list is told beforehand where
-- the cursor goes, and the row is looked for once more when the picker has
-- gone quiet, for the cases the first cannot cover.
local function panel_refresh(focus_id)
  if not panel_is_open() then
    return
  end
  local picker = panel.picker
  local current = picker:current()
  focus_id = focus_id or (current and current.pin.id)
  -- Where the pin will be once the list is filled again is known beforehand,
  -- from the same outline the finder reads. Given to the list as its target,
  -- the cursor is put there in the same redraw that brings the rows back, so
  -- it is never seen on the first row in between.
  if not is_searching(picker) then
    local number = 0
    for _, row in ipairs(outline(load(panel.root))) do
      if not row.hidden then
        number = number + 1
        if row.pin.id == focus_id then
          picker.list:set_target(number, picker.list.top, { force = true })
        end
      end
    end
  end
  picker:find()
  local tries = 0
  local function settle()
    if picker.closed then
      return
    end
    tries = tries + 1
    if picker:is_active() and tries < 100 then
      return vim.defer_fn(settle, 20)
    end
    for index, item in ipairs(picker:items()) do
      if item.pin.id == focus_id then
        picker.list:view(index)
        return
      end
    end
  end
  vim.defer_fn(settle, 20)
end

local function redraw_everything(root, focus_id)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.refresh(buf)
    end
  end
  if panel.root == root then
    panel_refresh(focus_id)
  end
end

function M.add()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    vim.notify("This buffer has no file to pin", vim.log.levels.WARN)
    return
  end
  local root = project_root(name)
  -- On a line that is pinned already the key is for that pin. A second pin on
  -- the same line is never what is meant, and this is how a pin is edited or
  -- taken off without opening the panel.
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, at in ipairs(pins_in(0, root, load(root))) do
    if at.line == cursor_line then
      local note = at.pin.memo ~= "" and at.pin.memo or "(no note)"
      vim.ui.select({ "Edit the note", "Remove the pin" }, { prompt = "Pinned: " .. note }, function(choice)
        if choice == "Edit the note" then
          M.edit(root, at.index)
        elseif choice == "Remove the pin" then
          M.remove(root, at.index)
          vim.notify("Pin removed (u in the pins panel brings it back)")
        end
      end)
      return
    end
  end
  local pin = {
    file = vim.fs.normalize(name):sub(#root + 2),
    line = vim.api.nvim_win_get_cursor(0)[1],
    text = vim.trim(vim.api.nvim_get_current_line()),
    symbol = enclosing_function(),
    created = os.date("%Y-%m-%d %H:%M"),
  }
  vim.ui.input({ prompt = "Pin note: " }, function(memo)
    if memo == nil then
      return
    end
    pin.memo = vim.trim(memo)
    local pins = load(root)
    remember(root)
    pin.id = new_id(pins)
    pins[#pins + 1] = pin
    save(root, pins)
    redraw_everything(root, pin.id)
  end)
end

function M.jump(root, index)
  local pins = load(root)
  local pin = pins[index]
  if not pin then
    return
  end
  local file = absolute(root, pin)
  if not vim.uv.fs_stat(file) then
    vim.notify("The pinned file is gone: " .. file, vim.log.levels.WARN)
    return
  end
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(file))
  local line, found = locate(0, pin)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
  if not found then
    vim.notify("The pinned line is no longer in the file; this is where it was", vim.log.levels.WARN)
  elseif line ~= pin.line then
    pin.line = line
    save(root, pins)
  end
  redraw_everything(root)
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

-- One pin goes without a question, so that several can be removed one after
-- the other; u in the panel brings it back.
function M.remove(root, index)
  local pins = load(root)
  if not pins[index] then
    return
  end
  remember(root)
  save(root, without(pins, pins[index].id))
  redraw_everything(root)
end

-- Several at once ask first, and come back with a single u.
function M.remove_many(root, ids)
  if #ids == 0 then
    return
  end
  if #ids > 1 and vim.fn.confirm(("Remove %d pins?"):format(#ids), "&Remove\n&Keep", 2) ~= 1 then
    return
  end
  local pins = load(root)
  remember(root)
  for _, id in ipairs(ids) do
    pins = without(pins, id)
  end
  save(root, pins)
  redraw_everything(root)
end

-- Steps back through the changes made in this session, and forward again.
function M.undo(root, forward)
  local steps = history[root] or { undo = {}, redo = {} }
  local from, to = steps.undo, steps.redo
  if forward then
    from, to = to, from
  end
  if #from == 0 then
    vim.notify(forward and "Nothing to redo" or "Nothing to undo")
    return
  end
  to[#to + 1] = load(root)
  save(root, table.remove(from))
  redraw_everything(root)
end

function M.edit(root, index, done)
  local pins = load(root)
  local pin = pins[index]
  if not pin then
    return
  end
  vim.ui.input({ prompt = "Pin note: ", default = pin.memo }, function(memo)
    if memo ~= nil then
      remember(root)
      pin.memo = vim.trim(memo)
      save(root, pins)
      redraw_everything(root, pin.id)
    end
    if done then
      done()
    end
  end)
end

-- Moves a pin among its siblings: -1 up, 1 down. The pins under it follow,
-- since they hang on its id and not on its position.
function M.move(root, id, direction)
  local pins = load(root)
  local index = index_of(pins, id)
  if not index then
    return
  end
  local other = index + direction
  while pins[other] and pins[other].parent ~= pins[index].parent do
    other = other + direction
  end
  if pins[other] then
    remember(root)
    pins[index], pins[other] = pins[other], pins[index]
    save(root, pins)
  end
  redraw_everything(root, id)
end

-- 1 makes the pin a child of the sibling above it; -1 moves it out to follow
-- its parent.
function M.shift(root, id, direction)
  local pins = load(root)
  local index = index_of(pins, id)
  if not index then
    return
  end
  local pin = pins[index]
  if direction > 0 then
    local above = index - 1
    while pins[above] and pins[above].parent ~= pin.parent do
      above = above - 1
    end
    if pins[above] then
      remember(root)
      pin.parent = pins[above].id
      -- So the pin stays in view under its new parent.
      pins[above].collapsed = nil
      -- Last among its new siblings.
      table.remove(pins, index)
      pins[#pins + 1] = pin
      save(root, pins)
    end
  elseif pin.parent then
    remember(root)
    local parent = pins[index_of(pins, pin.parent)]
    pin.parent = parent.parent
    table.remove(pins, index)
    table.insert(pins, index_of(pins, parent.id) + 1, pin)
    save(root, pins)
  end
  redraw_everything(root, id)
end

-- Opens or closes the pins under a pin: true, false, or nil to switch.
function M.fold(root, id, collapsed)
  local pins = load(root)
  local pin = pins[index_of(pins, id) or 0]
  if not pin then
    return
  end
  if collapsed == nil then
    collapsed = not pin.collapsed
  end
  pin.collapsed = collapsed or nil
  save(root, pins)
  redraw_everything(root, id)
end

function M.list()
  local root = project_root(vim.api.nvim_buf_get_name(0))
  local rows = outline(load(root))
  if #rows == 0 then
    vim.notify("No pins in " .. root .. " yet (<leader>jm pins a line)")
    return
  end
  local items = {}
  for _, row in ipairs(rows) do
    local pin = row.pin
    items[#items + 1] = {
      idx = row.index,
      depth = row.depth,
      text = table.concat({ pin.memo, pin.symbol, pin.file }, " "),
      file = absolute(root, pin),
      pos = { pin.line, 0 },
      pin = pin,
    }
  end
  local function reopen(picker)
    picker:close()
    vim.schedule(M.list)
  end
  Snacks.picker({
    title = "Pins",
    items = items,
    format = function(item)
      local pin = item.pin
      return {
        { ("  "):rep(item.depth) },
        { pin.memo ~= "" and pin.memo or "(no note)", pin.memo == "" and "Comment" or nil },
        { "  " },
        { pin.symbol, "Function" },
        { pin.symbol ~= "" and "  " or "" },
        { pin.file .. ":" .. pin.line, "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        M.jump(root, item.idx)
      end
    end,
    actions = {
      pin_remove = function(picker, item)
        if item then
          M.remove(root, item.idx)
          reopen(picker)
        end
      end,
      pin_edit = function(picker, item)
        if item then
          picker:close()
          M.edit(root, item.idx, vim.schedule_wrap(M.list))
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<a-d>"] = { "pin_remove", mode = { "n", "i" }, desc = "Remove pin" },
          ["<a-e>"] = { "pin_edit", mode = { "n", "i" }, desc = "Edit note" },
        },
      },
    },
  })
end

-- The panel is a picker laid out as a sidebar, as the file tree is: a filter
-- box on top and the list below it, staying open while files are read.
function M.toggle_panel()
  if panel_is_open() then
    panel.picker:close()
    panel.picker = nil
    return
  end
  local root = project_root(vim.api.nvim_buf_get_name(0))
  local look = tree_look()
  -- Kept here and not only on the filter, which is made anew for every search.
  local searching = false
  panel.root = root

  -- Arranging is for the whole tree in view: with a filter typed only part of
  -- it shows, and "one up" would move a pin past rows that cannot be seen.
  local function arrange(fn)
    return function(picker, item)
      if is_searching(picker) then
        vim.notify("Clear the filter to arrange the pins", vim.log.levels.WARN)
      elseif item then
        fn(item.pin.id)
      end
    end
  end

  panel.picker = Snacks.picker({
    source = "pins",
    title = "Pins",
    finder = function(_, ctx)
      local filtering = not ctx.filter:is_empty()
      -- Only while a filter is typed, as the file tree does it. With it on, the
      -- matcher ends every run by putting the cursor on the first match, which
      -- without a filter is the first row: the cursor jumped to the top after
      -- every change to the tree.
      ctx.picker.matcher.opts.keep_parents = filtering
      local items, by_id = {}, {}
      for number, row in ipairs(outline(load(root))) do
        -- A filter looks through closed pins too.
        if filtering or not row.hidden then
          local pin = row.pin
          local item = {
            text = table.concat({ pin.memo, pin.text, pin.symbol, pin.file }, " "),
            file = absolute(root, pin),
            pos = { pin.line, 0 },
            pin = pin,
            row = row,
            searching = filtering,
            -- What the matcher keeps a match's ancestors by, and what holds
            -- the rows in tree order whatever their score.
            parent = by_id[pin.parent or ""],
            sort = ("%06d"):format(number),
          }
          by_id[pin.id] = item
          items[#items + 1] = item
        end
      end
      return items
    end,
    format = function(item)
      return row_text(item.row, look, item.searching)
    end,
    filter = {
      -- Runs the finder again when the filter box goes from empty to not
      -- empty or back, since the two do not list the same rows.
      transform = function(picker, filter)
        local now = not filter:is_empty()
        if searching ~= now then
          searching = now
          filter.meta.searching = now
          return true
        end
      end,
    },
    -- Not fuzzy, as in the file tree: "aaaa" would match a note that merely has
    -- four a's somewhere in it.
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "sort" } },
    focus = "list",
    auto_close = false,
    jump = { close = false },
    -- On the right, away from the file tree. snacks takes two of its windows on
    -- the same side for a stack and sets each to half the height; side by side
    -- as they are, that halves the whole screen and leaves the lower half to an
    -- empty command line.
    layout = { preset = "sidebar", preview = false, layout = { position = "right" } },
    on_close = function()
      panel.picker = nil
    end,
    confirm = function(picker, item)
      if not item then
        return
      end
      if picker.main and vim.api.nvim_win_is_valid(picker.main) then
        vim.api.nvim_set_current_win(picker.main)
      end
      M.jump(root, index_of(load(root), item.pin.id))
    end,
    actions = {
      pin_up = arrange(function(id)
        M.move(root, id, -1)
      end),
      pin_down = arrange(function(id)
        M.move(root, id, 1)
      end),
      pin_in = arrange(function(id)
        M.shift(root, id, 1)
      end),
      pin_out = arrange(function(id)
        M.shift(root, id, -1)
      end),
      pin_fold = arrange(function(id)
        M.fold(root, id)
      end),
      pin_close = arrange(function(id)
        M.fold(root, id, true)
      end),
      pin_open = arrange(function(id)
        M.fold(root, id, false)
      end),
      -- The pins marked with Tab, or the one under the cursor.
      pin_remove = function(picker)
        local ids = vim.tbl_map(function(item)
          return item.pin.id
        end, picker:selected({ fallback = true }))
        picker.list:set_selected()
        if #ids == 1 then
          M.remove(root, index_of(load(root), ids[1]))
        else
          M.remove_many(root, ids)
        end
      end,
      pin_edit = function(_, item)
        if item then
          M.edit(root, index_of(load(root), item.pin.id))
        end
      end,
      pin_undo = function()
        M.undo(root)
      end,
      pin_redo = function()
        M.undo(root, true)
      end,
    },
    win = {
      list = {
        keys = {
          ["K"] = "pin_up",
          ["J"] = "pin_down",
          [">"] = "pin_in",
          ["<"] = "pin_out",
          -- Tab stays what it is in every picker and in the file tree: it marks
          -- a row, here for dd.
          ["za"] = "pin_fold",
          ["h"] = "pin_close",
          ["l"] = "pin_open",
          ["dd"] = "pin_remove",
          ["r"] = "pin_edit",
          ["u"] = "pin_undo",
          ["<C-r>"] = "pin_redo",
        },
      },
    },
  })
end

vim.keymap.set("n", "<leader>jm", M.add, { desc = "Pin this line with a note" })
vim.keymap.set("n", "<leader>jM", M.list, { desc = "Find a pin" })
vim.keymap.set("n", "<leader>jo", M.toggle_panel, { desc = "Pins panel (arrange)" })

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = vim.api.nvim_create_augroup("config_pins", { clear = true }),
  callback = function(event)
    M.refresh(event.buf)
  end,
})

return M

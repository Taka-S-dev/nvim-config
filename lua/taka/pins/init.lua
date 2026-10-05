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
--               <A-e> edits the note and <C-x> removes the pin (dd in the
--               list), as in the lists of buffers and marks
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

local store = require("taka.pins.store")
local project_root, load, save, remember, new_id =
  store.project_root, store.load, store.save, store.remember, store.new_id
local absolute, index_of, outline, without = store.absolute, store.index_of, store.outline, store.without
local locate, pins_in, history = store.locate, store.pins_in, store.history

local namespace = vim.api.nvim_create_namespace("config_pins")

-- A pin's sign and note take colours of their own: drawn at the end of a line
-- in a diagnostic's colour, a note read as a message from the language server,
-- which LazyVim puts there too. The note is in italics, as words added beside
-- the code and not part of it. Both follow the colour scheme (Label).
local function colours()
  local label = vim.api.nvim_get_hl(0, { name = "Label", link = false })
  vim.api.nvim_set_hl(0, "PinSign", { link = "Label", default = true })
  vim.api.nvim_set_hl(0, "PinNote", { fg = label.fg, italic = true, default = true })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_pins_colours", { clear = true }),
  callback = colours,
})

-- The mark of a pin, the bookmark the panel draws for one
-- (md-bookmark_outline).
local marker = "󰃃"

-- Whether the notes show at the ends of the lines (<leader>uN). The sign stays
-- either way, so a pinned line is still told apart.
local notes_shown = true

-- For the checks, which remove the files they leave behind.
M.store_path = store.store_path

-- The tree as the panel shows it, for the checks: "depth:note" per row.
function M.outline(root)
  return vim.tbl_map(function(row)
    return row.depth .. ":" .. row.pin.memo
  end, outline(load(root)))
end

-- The name of the function the cursor is in, where treesitter can tell.
local function enclosing_function()
  return require("taka.lib.enclosing").at(0, vim.api.nvim_win_get_cursor(0)[1])
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
      sign_text = marker,
      sign_hl_group = "PinSign",
      virt_text = notes_shown and at.pin.memo ~= "" and {
        { "  " .. marker .. " ", "PinSign" },
        { at.pin.memo, "PinNote" },
      } or nil,
      virt_text_pos = "eol",
    })
  end
  if moved then
    save(root, pins)
  end
end

function M.notes_shown()
  return notes_shown
end

-- The notes shown at the ends of the pinned lines, or put away, in every
-- buffer.
function M.show_notes(on)
  notes_shown = on
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.refresh(buf)
    end
  end
end

local function redraw_everything(root, focus_id)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.refresh(buf)
    end
  end
  require("taka.pins.panel").refresh(root, focus_id)
end

-- Pins for a chain of places, each under the one before, as the jump stack
-- (lua/taka/jump_stack.lua) keeps the jumps it holds. Each place is
-- { file, line, text, symbol, memo }, the file absolute. A pin is kept with
-- its project, so places outside the project of the first are left out. How
-- many were pinned, and the project.
function M.add_chain(places)
  if #places == 0 then
    return 0
  end
  local root = project_root(places[1].file)
  local pins = load(root)
  remember(root)
  local parent, added = nil, 0
  for _, place in ipairs(places) do
    local path = vim.fs.normalize(place.file)
    if path:lower():sub(1, #root + 1) == root:lower() .. "/" then
      local pin = {
        id = new_id(pins),
        parent = parent,
        file = path:sub(#root + 2),
        line = place.line,
        text = place.text or "",
        symbol = place.symbol or "",
        memo = place.memo or "",
        created = os.date("%Y-%m-%d %H:%M"),
      }
      pins[#pins + 1] = pin
      parent, added = pin.id, added + 1
    end
  end
  save(root, pins)
  redraw_everything(root, parent)
  return added, root
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
  if #load(root) == 0 then
    vim.notify("No pins in " .. root .. " yet (<leader>jm pins a line)")
    return
  end
  -- Read anew each time the list is drawn, so a pin removed from it goes from
  -- the list in place, the filter typed and the cursor kept, as a buffer does
  -- from the list of buffers.
  local function items()
    local out = {}
    for _, row in ipairs(outline(load(root))) do
      local pin = row.pin
      out[#out + 1] = {
        idx = row.index,
        depth = row.depth,
        text = table.concat({ pin.memo, pin.symbol, pin.file }, " "),
        file = absolute(root, pin),
        pos = { pin.line, 0 },
        pin = pin,
      }
    end
    return out
  end
  Snacks.picker({
    source = "pin_list",
    title = "Pins",
    finder = items,
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
      -- The pins marked with Tab, or the one under the cursor.
      pin_remove = function(picker)
        local ids = vim.tbl_map(function(item)
          return item.pin.id
        end, picker:selected({ fallback = true }))
        if #ids == 0 then
          return
        end
        picker.list:set_selected()
        if #ids == 1 then
          M.remove(root, index_of(load(root), ids[1]))
        else
          M.remove_many(root, ids)
        end
        picker.list:set_target()
        picker:find()
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
          ["<c-x>"] = { "pin_remove", mode = { "n", "i" }, desc = "Remove pin" },
          ["<a-e>"] = { "pin_edit", mode = { "n", "i" }, desc = "Edit note" },
        },
      },
      list = { keys = { ["dd"] = { "pin_remove", desc = "Remove the pin (Tab marks several)" } } },
    },
  })
end

M.toggle_panel = require("taka.pins.panel").toggle

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = vim.api.nvim_create_augroup("config_pins", { clear = true }),
  callback = function(event)
    M.refresh(event.buf)
  end,
})

return M

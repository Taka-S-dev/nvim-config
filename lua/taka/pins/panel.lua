-- The pins panel (<leader>jo): a sidebar on the right laid out as the file
-- tree is, with a filter box on top, where the pins are arranged.

local store = require("taka.pins.store")
local project_root, load, absolute, index_of, outline =
  store.project_root, store.load, store.absolute, store.index_of, store.outline

local function pins()
  return require("taka.pins")
end

local panel = { picker = nil, root = nil }

-- The panel is laid out the way the file tree next to it is: the same guide
-- characters, read from snacks at draw time, and a marker of one width on every
-- row, so the notes of one level start in one column. The markers are one
-- family, the way a folder is one shape open and closed: a bookmark for a pin,
-- a stack of bookmarks for a pin with pins under it, in outline while they
-- show and filled while they are closed. They come from the Nerd Font the rest
-- of the UI already needs (md-bookmark_outline, md-bookmark_multiple_outline,
-- md-bookmark_multiple).
local markers = { leaf = "󰃃 ", open = "󰸖 ", closed = "󰸕 " }

local tree_look = require("taka.lib.sidebar").tree_look

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
    { marker, "PinSign" },
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
-- where it was (lua/taka/lib/sidebar.lua). Where the pin will be once the list
-- is filled again is known beforehand, from the same outline the finder reads,
-- except while a filter is typed.
local function panel_refresh(focus_id)
  if not panel_is_open() then
    return
  end
  local picker = panel.picker
  local current = picker:current()
  focus_id = focus_id or (current and current.pin.id)
  local target
  if not is_searching(picker) then
    local number = 0
    for _, row in ipairs(outline(load(panel.root))) do
      if not row.hidden then
        number = number + 1
        if row.pin.id == focus_id then
          target = number
        end
      end
    end
  end
  require("taka.lib.sidebar").refresh(picker, target, function(item)
    return item.pin.id == focus_id
  end)
end

-- The panel is a picker laid out as a sidebar, as the file tree is: a filter
-- box on top and the list below it, staying open while files are read.
local function toggle()
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
    layout = require("taka.lib.sidebar").layout(),
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
      pins().jump(root, index_of(load(root), item.pin.id))
    end,
    actions = {
      pin_up = arrange(function(id)
        pins().move(root, id, -1)
      end),
      pin_down = arrange(function(id)
        pins().move(root, id, 1)
      end),
      pin_in = arrange(function(id)
        pins().shift(root, id, 1)
      end),
      pin_out = arrange(function(id)
        pins().shift(root, id, -1)
      end),
      pin_fold = arrange(function(id)
        pins().fold(root, id)
      end),
      pin_close = arrange(function(id)
        pins().fold(root, id, true)
      end),
      pin_open = arrange(function(id)
        pins().fold(root, id, false)
      end),
      -- The pins marked with Tab, or the one under the cursor.
      pin_remove = function(picker)
        local ids = vim.tbl_map(function(item)
          return item.pin.id
        end, picker:selected({ fallback = true }))
        picker.list:set_selected()
        if #ids == 1 then
          pins().remove(root, index_of(load(root), ids[1]))
        else
          pins().remove_many(root, ids)
        end
      end,
      pin_edit = function(_, item)
        if item then
          pins().edit(root, index_of(load(root), item.pin.id))
        end
      end,
      pin_undo = function()
        pins().undo(root)
      end,
      pin_redo = function()
        pins().undo(root, true)
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
          ["<c-x>"] = "pin_remove",
          ["r"] = "pin_edit",
          ["u"] = "pin_undo",
          ["<C-r>"] = "pin_redo",
        },
      },
    },
  })
end

return {
  toggle = toggle,
  -- The panel drawn again if it shows the pins of `root`.
  refresh = function(root, focus_id)
    if panel.root == root then
      panel_refresh(focus_id)
    end
  end,
}

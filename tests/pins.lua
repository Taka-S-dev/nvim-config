-- Pins (lua/taka/pins/).
return function(T)
  local check, expect, temp_dir, write, key, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.key, T.reset_editor

  check("pins: a line is pinned with a note, kept, found again after it moved, removed", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 40 do
      lines[i] = ("int value_%d = %d;"):format(i, i)
    end
    write(dir .. "/GTAGS", {})
    write(dir .. "/src/a.c", lines)
    local root = vim.fs.normalize(dir)
    local pins = require("taka.pins")
    local store = pins.store_path(root)
    local input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("length is checked here")
    end
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/src/a.c")
      vim.fn.cursor(20, 1)
      key("<leader>jm")()
      local namespace = vim.api.nvim_get_namespaces().config_pins
      local marks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
      local function note()
        local chunks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })[1][4].virt_text or {}
        return table.concat(
          vim.tbl_map(function(chunk)
            return chunk[1] .. "|" .. chunk[2]
          end, chunks),
          " "
        )
      end
      seen.mark = #marks == 1 and marks[1][2] == 19 and note():find("length is checked here|PinNote", 1, true) ~= nil
      -- <leader>uN puts the notes away and brings them back; the sign stays.
      pins.show_notes(false)
      local sign = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })[1][4].sign_text
      seen.hidden = note() .. "/" .. vim.trim(sign or "")
      pins.show_notes(true)
      seen.shown_again = note():find("length is checked here", 1, true) ~= nil
      -- A new session reads the file again, and by then the line has moved.
      package.loaded["taka.pins"] = nil
      pins = require("taka.pins")
      table.insert(lines, 1, "/* three */")
      table.insert(lines, 1, "/* lines */")
      table.insert(lines, 1, "/* added */")
      vim.cmd("silent! %bwipeout!")
      write(dir .. "/src/a.c", lines)
      vim.cmd.edit(dir .. "/src/other.c")
      pins.jump(root, 1)
      seen.landed = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".") .. ":" .. vim.trim(vim.fn.getline("."))
      local stored = vim.json.decode(table.concat(vim.fn.readfile(store)))
      seen.stored = stored.pins[1].file .. ":" .. stored.pins[1].line .. ":" .. stored.pins[1].memo
      pins.remove(root, 1)
      seen.left = #vim.json.decode(table.concat(vim.fn.readfile(store))).pins
    end)
    vim.ui.input = input
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.mark, "the pinned line shows no mark with its note")
    expect(seen.hidden == "/󰃃", "with the notes put away, note/sign: " .. tostring(seen.hidden))
    expect(seen.shown_again, "the note did not come back")
    expect(seen.landed == "a.c:23:int value_20 = 20;", "landed on " .. tostring(seen.landed))
    expect(seen.stored == "src/a.c:23:length is checked here", "stored as " .. tostring(seen.stored))
    expect(seen.left == 0, "the pin was not removed")
  end)
  -- The ways a note was lost or shown in the wrong place: a mark drawn at the
  -- old line number after the file changed outside, the pin key making a
  -- second pin on a line that had one, and a slip of dd. One pin goes without
  -- a question and comes back with u; several at once ask first.
  check("pins: marks follow the line, the key acts on an existing pin, removal can be undone", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 30 do
      lines[i] = ("int value_%d = %d;"):format(i, i)
    end
    write(dir .. "/GTAGS", {})
    write(dir .. "/a.c", lines)
    local root = vim.fs.normalize(dir)
    local pins = require("taka.pins")
    local store = pins.store_path(root)
    local input, select, confirm = vim.ui.input, vim.ui.select, vim.fn.confirm
    local seen = {}
    local function stored()
      return vim.json.decode(table.concat(vim.fn.readfile(store))).pins
    end
    local function marked_lines()
      local rows = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().config_pins, 0, -1, {})) do
        rows[#rows + 1] = mark[2] + 1
      end
      return table.concat(rows, ",")
    end
    local ok, err = pcall(function()
      vim.ui.input = function(_, on_confirm)
        on_confirm("first note")
      end
      vim.cmd.edit(dir .. "/a.c")
      vim.fn.cursor(10, 1)
      key("<leader>jm")()

      -- The file changes outside the editor: five lines go in above the pin.
      vim.cmd("silent! %bwipeout!")
      for _ = 1, 5 do
        table.insert(lines, 1, "/* added */")
      end
      write(dir .. "/a.c", lines)
      vim.cmd.edit(dir .. "/a.c")
      seen.mark_after_change = marked_lines()
      seen.line_after_change = stored()[1].line

      -- The key on the pinned line offers the pin, and makes no second one.
      local offered
      vim.ui.select = function(choices, _, on_choice)
        offered = table.concat(choices, "|")
        on_choice("Edit the note")
      end
      vim.ui.input = function(options, on_confirm)
        seen.default = options.default
        on_confirm("second note")
      end
      vim.fn.cursor(15, 1)
      key("<leader>jm")()
      seen.offered = offered
      seen.after_edit = #stored() .. ":" .. stored()[1].memo

      -- Taken off from its line: no question, and u brings it back.
      local asked = 0
      vim.fn.confirm = function()
        asked = asked + 1
        return 2
      end
      vim.ui.select = function(_, _, on_choice)
        on_choice("Remove the pin")
      end
      key("<leader>jm")()
      seen.removed = #stored()
      seen.mark_after_removal = marked_lines()
      seen.asked_for_one = asked
      pins.undo(root)
      seen.undone = #stored() .. ":" .. stored()[1].memo .. ":" .. marked_lines()
      pins.undo(root, true)
      seen.redone = #stored()
      pins.undo(root)

      -- Several at once: a question, "keep" keeps them, and one u restores all.
      vim.ui.select = select
      vim.ui.input = function(_, on_confirm)
        on_confirm("another")
      end
      vim.fn.cursor(20, 1)
      key("<leader>jm")()
      local ids = vim.tbl_map(function(pin)
        return pin.id
      end, stored())
      pins.remove_many(root, ids)
      seen.kept = #stored() .. " after " .. asked .. " question"
      vim.fn.confirm = function()
        return 1
      end
      pins.remove_many(root, ids)
      seen.all_gone = #stored()
      pins.undo(root)
      seen.all_back = #stored()
    end)
    vim.ui.input, vim.ui.select, vim.fn.confirm = input, select, confirm
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.mark_after_change == "15", "the mark is drawn on line " .. tostring(seen.mark_after_change))
    expect(seen.line_after_change == 15, "the stored line is " .. tostring(seen.line_after_change))
    expect(
      seen.offered == "Edit the note|Remove the pin",
      "on a pinned line the key offered: " .. tostring(seen.offered)
    )
    expect(seen.default == "first note", "the note to edit was not filled in")
    expect(seen.after_edit == "1:second note", "after editing from the line: " .. tostring(seen.after_edit))
    expect(seen.removed == 0 and seen.mark_after_removal == "", "removing from the line left something behind")
    expect(seen.asked_for_one == 0, "removing one pin asked a question")
    expect(seen.undone == "1:second note:15", "after undo: " .. tostring(seen.undone))
    expect(seen.redone == 0, "redo did not remove it again")
    expect(seen.kept == "2 after 1 question", "removing several, answered keep: " .. tostring(seen.kept))
    expect(seen.all_gone == 0 and seen.all_back == 2, "several removed, then one undo: " .. tostring(seen.all_back))
  end)
  -- A pin stores its path relative to its project. With no GTAGS or .git above
  -- the file and the cwd somewhere else, that path was cut against the cwd and
  -- pointed at nothing.
  check("pins: a file outside the cwd, in no project, is pinned where it is", function()
    local elsewhere = temp_dir()
    write(elsewhere .. "/sub/far.c", { "int x;", "int y;" })
    local pins = require("taka.pins")
    local store = pins.store_path(vim.fs.normalize(elsewhere .. "/sub"))
    local input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("outside")
    end
    local stored, landed
    local ok, err = pcall(function()
      vim.cmd.edit(elsewhere .. "/sub/far.c")
      vim.fn.cursor(2, 1)
      key("<leader>jm")()
      stored = vim.json.decode(table.concat(vim.fn.readfile(store)))
      vim.cmd.edit(elsewhere .. "/sub/other.c")
      pins.jump(stored.root, 1)
      landed = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    end)
    vim.ui.input = input
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(stored.pins[1].file == "far.c", "stored as " .. tostring(stored.pins[1].file))
    expect(landed == "far.c:2", "landed on " .. tostring(landed))
  end)
  check("pins: the panel nests, reorders, filters and removes without losing a note", function()
    local dir = temp_dir()
    write(dir .. "/GTAGS", {})
    write(dir .. "/a.c", { "int a;", "int b;", "int c;", "int d;" })
    local root = vim.fs.normalize(dir)
    local pins = require("taka.pins")
    local store = pins.store_path(root)
    -- A file from before pins had ids or parents.
    local legacy = { file = "a.c", line = 1, text = "int a;", symbol = "", memo = "A" }
    write(store, { vim.json.encode({ root = root, pins = { legacy } }) })
    local input = vim.ui.input
    local notify = vim.notify
    local warned = 0
    local seen = {}
    local picker
    local function tree()
      return table.concat(pins.outline(root), " ")
    end
    local function rows()
      -- A change to the filter box reaches the finder a moment later.
      vim.wait(300)
      vim.wait(3000, function()
        return not picker:is_active()
      end, 20)
      vim.wait(100)
      return vim.tbl_map(function(item)
        local text = ""
        for _, chunk in ipairs(picker.opts.format(item, picker)) do
          -- The place is virtual text at the right edge, not part of the line.
          local part = chunk[1]
          if chunk.virt_text then
            seen.right_edge = seen.right_edge or chunk.virt_text_pos == "right_align"
            part = " @" .. chunk.virt_text[2][1]
          end
          text = text .. part
          -- "Normal" brings the background of the editing windows with it: a
          -- box on the sidebar, and a hole in the line under the cursor.
          seen.boxed = seen.boxed or chunk[2] == "Normal"
        end
        return text
      end, picker:items())
    end
    local leaves_the_pin = { pin_remove = true, pin_undo = true, confirm = true, select_and_next = true }
    local function on_row(note, action)
      for index, item in ipairs(picker:items()) do
        if item.pin.memo == note then
          picker.list:view(index)
        end
      end
      -- Every move of the list cursor while the change is drawn: a visit to the
      -- first row on the way shows as a flash at the top of the panel.
      local set_cursor, visited = vim.api.nvim_win_set_cursor, {}
      vim.api.nvim_win_set_cursor = function(win, position)
        if win == picker.list.win.win then
          visited[#visited + 1] = position[1]
        end
        return set_cursor(win, position)
      end
      picker:action(action)
      rows()
      vim.api.nvim_win_set_cursor = set_cursor
      local final = vim.api.nvim_win_get_cursor(picker.list.win.win)[1]
      if final ~= 1 and vim.tbl_contains(visited, 1) and not leaves_the_pin[action] then
        seen.flashed = seen.flashed or (action .. " on " .. note)
      end
      -- The list is filled again after every change, which takes the cursor to
      -- the first row unless it is put back on the pin that was acted on.
      local current = picker:current()
      if not leaves_the_pin[action] and (not current or current.pin.memo ~= note) then
        seen.cursor_lost = seen.cursor_lost or (action .. " on " .. note)
      end
    end
    -- As typing does it: the text goes into the filter box and the box is told
    -- that it changed.
    local function type_filter(text)
      local buf = picker.input.win.buf
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      rows()
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      for line, note in ipairs({ false, "B", "C", "D" }) do
        if note then
          vim.ui.input = function(_, on_confirm)
            on_confirm(note)
          end
          vim.fn.cursor(line, 1)
          key("<leader>jm")()
        end
      end
      seen.added = tree()
      -- With the file tree open as well: two snacks sidebars on one side are
      -- each set to half the height, which left the lower half of the screen
      -- to an empty command line.
      Snacks.explorer({ cwd = dir })
      vim.wait(800)
      vim.cmd("wincmd p")
      local command_line = vim.o.cmdheight
      key("<leader>jo")()
      vim.wait(800)
      seen.screen_kept = vim.o.cmdheight == command_line
      for _, tree_picker in ipairs(Snacks.picker.get({ source = "explorer" })) do
        tree_picker:close()
      end
      picker = Snacks.picker.get({ source = "pins" })[1]
      expect(picker ~= nil, "the panel did not open")
      rows()
      seen.keys = vim.fn.maparg("K", "n", false, true).desc ~= nil
      on_row("C", "pin_in")
      on_row("D", "pin_in")
      on_row("D", "pin_out")
      on_row("D", "pin_in")
      seen.nested = tree()
      seen.guides = "\n" .. table.concat(rows(), "\n")
      on_row("B", "pin_fold")
      seen.closed = #rows()
      seen.kept_closed = vim.json.decode(table.concat(vim.fn.readfile(store))).pins[2].collapsed
      -- A filter finds a pin under a closed one and shows it under its parent,
      -- and nothing can be arranged meanwhile.
      vim.notify = function()
        warned = warned + 1
      end
      type_filter("D")
      seen.filtered = table.concat(rows(), "|")
      local before = tree()
      on_row("D", "pin_out")
      seen.frozen = tree() == before
      type_filter("")
      vim.notify = notify
      on_row("B", "pin_open")
      seen.opened = #rows()
      on_row("B", "pin_up")
      seen.moved = tree()
      on_row("B", "pin_remove")
      seen.removed = tree()
      -- Marked with Tab and removed together, then brought back with one u.
      on_row("C", "select_and_next")
      on_row("D", "select_and_next")
      on_row("A", "pin_remove")
      seen.marked_removed = tree()
      on_row("A", "pin_undo")
      seen.marked_back = tree()
      on_row("D", "confirm")
      seen.jumped = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      seen.still_open = not picker.closed
    end)
    vim.ui.input = input
    vim.notify = notify
    if picker and not picker.closed then
      picker:close()
    end
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.added == "0:A 0:B 0:C 0:D", "a new pin goes to the end, at the top level: " .. tostring(seen.added))
    expect(seen.screen_kept, "opening the panel beside the file tree grew the command line")
    expect(seen.right_edge, "the place is not at the right edge of the row")
    expect(not seen.boxed, "a row is drawn with the background of the editing windows")
    expect(not seen.flashed, "the cursor went by the first row after " .. tostring(seen.flashed))
    expect(not seen.cursor_lost, "the cursor left the pin after " .. tostring(seen.cursor_lost))
    expect(seen.nested == "0:A 0:B 1:C 1:D", "nesting under the pin above: " .. tostring(seen.nested))
    local drawn = seen.guides or ""
    expect(
      drawn:find("\n[^ ╴]+ B @a.c:2")
        and drawn:find("\n├╴[^ ]+ C @a.c:3")
        and drawn:find("\n└╴[^ ]+ D @a.c:4"),
      "guide lines: " .. drawn
    )
    expect(
      seen.closed == 2 and seen.opened == 4,
      ("closing B leaves %s rows, opening it %s"):format(seen.closed, seen.opened)
    )
    expect(seen.kept_closed == true, "what is closed is not stored")
    expect(
      (seen.filtered or ""):find("^[^ ╴]+ B @.*|└╴[^ ]+ D @") and not seen.filtered:find(" [AC] @"),
      "a filter keeps the match under its parent and drops the rest: " .. tostring(seen.filtered)
    )
    expect(seen.frozen and warned == 1, "arranging went on while a filter was typed")
    expect(seen.moved == "0:B 1:C 1:D 0:A", "a pin moves with the pins under it: " .. tostring(seen.moved))
    expect(seen.removed == "0:C 0:D 0:A", "removing a parent keeps its children: " .. tostring(seen.removed))
    expect(seen.marked_removed == "0:A", "dd with two pins marked left: " .. tostring(seen.marked_removed))
    expect(seen.marked_back == "0:C 0:D 0:A", "u after that: " .. tostring(seen.marked_back))
    expect(seen.jumped == "a.c:4", "Enter in the panel: " .. tostring(seen.jumped))
    expect(seen.still_open, "the panel closed on a jump")
  end)

  -- In the list of <leader>jM a pin is removed with <C-x>, as a buffer is in
  -- the list of buffers and a mark in the list of marks: it goes from the list
  -- in place, the list staying open with what was typed in its filter.
  check("pins: <C-x> in the list removes a pin in place, the filter kept", function()
    local dir = temp_dir()
    write(dir .. "/GTAGS", {})
    write(dir .. "/a.c", { "int a;", "int b;", "int c;" })
    local root = vim.fs.normalize(dir)
    local pins = require("taka.pins")
    local store = pins.store_path(root)
    local seen = {}
    local picker
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      local places = {}
      for line, memo in ipairs({ "keep one", "drop this", "keep two" }) do
        places[#places + 1] = { file = dir .. "/a.c", line = line, text = "", symbol = "", memo = memo }
      end
      pins.add_chain(places)
      key("<leader>jM")()
      picker = Snacks.picker.get({ source = "pin_list" })[1]
      expect(picker, "the list did not open")
      vim.wait(1000, function()
        return #picker:items() == 3
      end, 20)
      -- Typed as the panel's check does: a headless run has no keys to type.
      local input = picker.input.win.buf
      vim.api.nvim_buf_set_lines(input, 0, -1, false, { "drop" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = input })
      vim.wait(1000, function()
        return #picker:items() == 1
      end, 20)
      seen.mapped = vim.tbl_contains(
        vim.tbl_map(function(map)
          return map.lhs
        end, vim.api.nvim_buf_get_keymap(input, "i")),
        "<C-X>"
      )
      picker:action("pin_remove")
      vim.wait(1000, function()
        return #picker:items() == 0
      end, 20)
      seen.open = not picker.closed
      seen.filter = picker.input:get()
      seen.left = pins.outline(root)
    end)
    if picker and not picker.closed then
      picker:close()
    end
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.mapped, "<C-x> is not a key of the list")
    expect(seen.open, "the list closed when a pin was removed")
    expect(seen.filter == "drop", "the filter became " .. vim.inspect(seen.filter))
    expect(
      -- The pins are a chain, each under the one before: the one under the
      -- pin removed moves up into its place.
      vim.deep_equal(seen.left, { "0:keep one", "1:keep two" }),
      "the pins left: " .. vim.inspect(seen.left)
    )
  end)
end

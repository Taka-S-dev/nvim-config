-- Text lit: the selection's other occurrences and the lit words.
return function(T)
  local check, expect, temp_dir, write, run, key, press, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.run, T.key, T.press, T.reset_editor

  -- The text selected is lit where else it stands, as it stands: case
  -- counts, and the brackets of `[17]` are no pattern. A selection of one
  -- character, of blanks or over two lines lights nothing, and leaving the
  -- selection puts the rest out. A headless run moves no cursor through the
  -- screen, so what CursorMoved would call is called here.
  check("selection matches: the text selected is lit where else it stands", function()
    local matches = require("taka.selection_matches")
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "foo(bar) + foo(bar)",
      "  int foo = 1;",
      "[17] and [17] and [1]",
      "FOO foo",
      "値を返す 値を",
    })
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      local function select(row, col, keys)
        press("<Esc>")
        vim.api.nvim_win_set_cursor(0, { row, col })
        press("v" .. keys)
        matches.update()
        return table.concat(matches.marks(), " ")
      end
      seen.word = select(1, 0, "ll")
      seen.brackets = select(3, 0, "3l")
      seen.japanese = select(5, 0, "l")
      seen.one = select(1, 0, "")
      seen.blanks = select(2, 0, "l")
      -- From the second foo(bar) down a line: the first line's part of it
      -- stands at the start of the line too, and is not lit.
      seen.lines = select(1, 11, "j")
      select(1, 0, "ll")
      press("<Esc>")
      seen.left = table.concat(matches.marks(), " ")
    end)
    press("<Esc>")
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.word == "1:12 2:7 4:5", "foo: " .. tostring(seen.word))
    expect(seen.brackets == "3:10", "[17]: " .. tostring(seen.brackets))
    expect(seen.japanese == "5:14", "値を: " .. tostring(seen.japanese))
    expect(
      seen.one == "" and seen.blanks == "" and seen.lines == "",
      ("one character, blanks, two lines: %q %q %q"):format(seen.one, seen.blanks, seen.lines)
    )
    expect(seen.left == "", "left after the selection: " .. tostring(seen.left))
  end)
  -- The word under the cursor is lit where else it stands on screen, whole
  -- and with its case: len is not lit in buflen, nor LEN. Nothing is lit on a
  -- blank, for a word that stands nowhere else, or in Insert mode. A C file
  -- has no language server here, and nothing was lit at all.
  check("cursor word: the word under the cursor is lit where else it stands", function()
    local cursor_word = require("taka.cursor_word")
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "int len = 0;",
      "int buflen = len + LEN;",
      "return len;",
      "int once_only;",
    })
    local seen = {}
    local function at(row, col)
      vim.api.nvim_win_set_cursor(0, { row, col })
      cursor_word.update()
      return table.concat(cursor_word.marks(), " ")
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      seen.word = at(1, 5)
      seen.blank = at(1, 3)
      seen.once = at(4, 6)
      -- A word lit in a colour of its own: the green drawn over its colour,
      -- as a match above the colour's, and taken off once the cursor leaves.
      local function over()
        local out = {}
        for _, match in ipairs(vim.fn.getmatches()) do
          out[#out + 1] = match.group .. "@" .. match.priority .. "=" .. match.pattern
        end
        table.sort(out)
        return table.concat(out, " ")
      end
      vim.api.nvim_win_set_cursor(0, { 1, 5 })
      require("taka.words").toggle()
      seen.coloured = at(3, 8)
      seen.coloured_look = over()
      at(4, 0)
      seen.left = over()
      -- Put out under the cursor: left unlit, the green as well, until the
      -- cursor goes to another word, so that it is seen to have gone out.
      at(3, 8)
      require("taka.words").toggle()
      seen.out = table.concat(cursor_word.marks(), " ") .. "|" .. over()
      seen.out_still = at(1, 5)
      at(4, 0)
      seen.back = at(3, 8)
      require("taka.words").toggle()
      at(3, 8)
      require("taka.words").clear()
      seen.cleared = table.concat(cursor_word.marks(), " ") .. "|" .. over()
      -- Moved onto the word for real: lit once the cursor has rested.
      at(4, 6)
      vim.api.nvim_win_set_cursor(0, { 3, 8 })
      vim.api.nvim_exec_autocmds("CursorMoved", {})
      seen.at_once = table.concat(cursor_word.marks(), " ")
      vim.wait(cursor_word.DELAY + 500, function()
        return #cursor_word.marks() > 0
      end, 20)
      seen.rested = table.concat(cursor_word.marks(), " ")
      -- Entering Insert mode, as InsertEnter tells of it: a headless run
      -- left in Insert mode by keys fed to it took the next checks' keys as
      -- text.
      vim.api.nvim_exec_autocmds("InsertEnter", {})
      vim.wait(cursor_word.DELAY + 200)
      seen.insert = table.concat(cursor_word.marks(), " ")
    end)
    press("<Esc>")
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.word == "1:5 2:14 3:8", "len: " .. tostring(seen.word))
    expect(seen.blank == "", "on a blank: " .. tostring(seen.blank))
    expect(seen.once == "", "a word that stands nowhere else: " .. tostring(seen.once))
    expect(seen.coloured == "1:5 2:14 3:8", "len lit in a colour: " .. tostring(seen.coloured))
    expect(
      seen.coloured_look == [[CursorWordMatch@11=\V\<len\> Word1@10=\V\<len\>]],
      "over len lit in a colour: " .. tostring(seen.coloured_look)
    )
    expect(seen.left == [[Word1@10=\V\<len\>]], "the cursor gone from len: " .. tostring(seen.left))
    expect(seen.out == "|", "len put out under the cursor: " .. tostring(seen.out))
    expect(seen.out_still == "", "len put out, the cursor still on it: " .. tostring(seen.out_still))
    expect(seen.back == "1:5 2:14 3:8", "back on len from another word: " .. tostring(seen.back))
    expect(seen.cleared == "|", "every word put out, the cursor on len: " .. tostring(seen.cleared))
    expect(seen.at_once == "", "lit before the cursor rested: " .. tostring(seen.at_once))
    expect(seen.rested == "1:5 2:14 3:8", "after resting on len: " .. tostring(seen.rested))
    expect(seen.insert == "", "in Insert mode: " .. tostring(seen.insert))
    -- In the green the references a language server lights are given
    -- (lua/plugins/colorscheme.lua), not the blue grey of the cursor line,
    -- which on the cursor line, where the word under the cursor is, could
    -- hardly be told.
    local line = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg
    for _, name in ipairs({ "CursorWordMatch", "SelectionMatch", "LspReferenceText" }) do
      local bg = vim.api.nvim_get_hl(0, { name = name, link = false }).bg
      expect(bg == 0x21503c, ("%s is #%06x, not the green"):format(name, bg or 0))
      expect(bg ~= line, name .. " is the cursor line's colour")
    end
  end)
  check("words: past the last colour, the words lit go round the colours again", function()
    local words = require("taka.words")
    local dir = temp_dir()
    local names = {}
    for index = 1, 12 do
      names[index] = "w" .. index
    end
    write(dir .. "/a.c", { table.concat(names, " ") .. " " })
    vim.cmd.edit(dir .. "/a.c")
    local function colour_of(name)
      for _, match in ipairs(vim.fn.getmatches(0)) do
        if match.pattern == [[\V\<]] .. name .. [[\>]] then
          return match.group
        end
      end
    end
    local function light(name)
      vim.fn.cursor(1, vim.fn.stridx(vim.fn.getline(1), name .. " ") + 1)
      words.toggle()
    end
    for _, name in ipairs(names) do
      light(name)
    end
    local seen = {}
    for _, name in ipairs(names) do
      seen[#seen + 1] = colour_of(name)
    end
    -- One put out frees its colour, which the next word lit takes.
    light("w3")
    light("w3")
    local freed = colour_of("w3")
    words.clear()
    reset_editor()
    local want = {}
    for index = 1, 10 do
      want[index] = "Word" .. index
    end
    want[11], want[12] = "Word1", "Word2"
    expect(vim.deep_equal(seen, want), "colours: " .. table.concat(seen, " "))
    expect(freed == "Word3", "w3 put out and lit again: " .. tostring(freed))
  end)

  check("words: several words stay lit across files and windows, and are stepped through", function()
    local words = require("taka.words")
    local dir = temp_dir()
    write(dir .. "/a.c", { "int len = 0;", "int buflen = len + 1;", "return len;" })
    write(dir .. "/b.c", { "size_t len;", "len = 2;" })
    local function lit(win)
      local names = {}
      for _, match in ipairs(vim.fn.getmatches(win)) do
        names[#names + 1] = match.group .. "=" .. match.pattern
      end
      table.sort(names)
      return table.concat(names, " ")
    end
    vim.cmd.edit(dir .. "/a.c")
    vim.fn.cursor(1, 5)
    key("<leader>hh")()
    vim.fn.cursor(1, 1)
    key("<leader>hh")()
    local two = lit(0)
    -- A selection lit inside a lit word: on the selection the key puts out
    -- the selection, drawn on top, and elsewhere on the word the word.
    write(dir .. "/d.c", { "static char *app_get_pass(long x)" })
    vim.cmd.edit(dir .. "/d.c")
    vim.fn.cursor(1, 15)
    key("<leader>hh")()
    vim.fn.cursor(1, 21)
    press("v4l")
    words.toggle()
    press("")
    local function patterns()
      return table.concat(
        vim.tbl_map(function(match)
          return match.pattern
        end, vim.fn.getmatches()),
        " "
      )
    end
    local nested = patterns()
    vim.fn.cursor(1, 22)
    key("<leader>hh")()
    local on_selection = patterns()
    vim.fn.cursor(1, 15)
    key("<leader>hh")()
    local on_word = patterns()
    vim.cmd.edit(dir .. "/a.c")
    vim.cmd.edit(dir .. "/b.c")
    local other_file = lit(0)
    vim.cmd("vsplit")
    local new_window = lit(0)
    vim.cmd("close")
    vim.fn.cursor(1, 1)
    key("<leader>hn")()
    local first = vim.fn.line(".") .. ":" .. vim.fn.col(".")
    key("<leader>hn")()
    local second = vim.fn.line(".") .. ":" .. vim.fn.col(".")
    -- The panel lists every place in the open files as a tree with counts,
    -- jumps from a line, follows a file opened later, and follows the words
    -- as they are put out.
    key("<leader>ho")()
    local panel = Snacks.picker.get({ source = "words" })[1]
    expect(panel ~= nil, "the words panel did not open")
    local function rows()
      vim.wait(300)
      vim.wait(3000, function()
        return not panel:is_active()
      end, 50)
      local out = {}
      for _, item in ipairs(panel:items()) do
        if item.kind == "line" then
          out[#out + 1] = item.word.label .. "@" .. vim.fs.basename(item.file) .. ":" .. item.pos[1]
        else
          out[#out + 1] = item.kind
            .. ":"
            .. (item.kind == "word" and item.word.label or vim.fs.basename(item.file))
            .. "="
            .. item.count
        end
      end
      return out
    end
    local listed = table.concat(rows(), " ")
    vim.cmd("wincmd p")
    write(dir .. "/c.c", { "int len;" })
    vim.cmd.edit(dir .. "/c.c")
    local after_open = #rows()
    vim.api.nvim_set_current_win(panel.list.win.win)
    local last
    for index, item in ipairs(panel:items()) do
      if item.kind == "line" then
        last = index
      end
    end
    panel.list:view(last)
    panel:action("confirm")
    vim.wait(300)
    local jumped = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    vim.api.nvim_set_current_win(panel.list.win.win)
    panel.list:view(1)
    panel:action("word_out")
    local rows_after = #rows()
    panel:close()
    vim.cmd("wincmd p")
    local one = lit(vim.api.nvim_get_current_win())
    words.clear()
    local none = lit(0)
    reset_editor()
    expect(two == [[Word1=\V\<len\> Word2=\V\<int\>]], "two words lit: " .. two)
    expect(nested == [[\V\<len\> \V\<int\> \V\<app_get_pass\> \V_pass]], "a selection lit in a word: " .. nested)
    expect(on_selection == [[\V\<len\> \V\<int\> \V\<app_get_pass\>]], "the key on the selection: " .. on_selection)
    expect(on_word == [[\V\<len\> \V\<int\>]], "the key on the rest of the word: " .. on_word)
    expect(other_file == two, "in another file: " .. other_file)
    expect(new_window == two, "in a new window: " .. new_window)
    expect(first == "1:8" and second == "2:1", ("stepping landed on %s then %s"):format(first, second))
    expect(
      listed
        == "word:len=5 file:a.c=3 len@a.c:1 len@a.c:2 len@a.c:3 file:b.c=2 len@b.c:1 len@b.c:2 word:int=2 file:a.c=2 int@a.c:1 int@a.c:2",
      "the panel listed: " .. listed
    )
    expect(after_open == 16, ("after opening a third file the panel has %d rows, not 16"):format(after_open))
    expect(jumped == "c.c:1", "Enter on the last line went to " .. jumped)
    expect(rows_after == 6, ("after dd on len the panel has %d rows, not 6"):format(rows_after))
    expect(one == [[Word2=\V\<int\>]], "after putting len out: " .. one)
    expect(none == "", "after clearing: " .. none)
  end)

  -- Lines marked by hand with <leader>hl, their background tinted: a line,
  -- or the lines selected, marked and taken off again with the same key; a
  -- mark moves with its line; <leader>hj and <leader>hk go round them, and
  -- <leader>hL takes them all off.
  check("line marks: lines marked, followed through edits, stepped through, taken off", function()
    local marks = require("taka.line_marks")
    local dir = temp_dir()
    local lines = {}
    for i = 1, 20 do
      lines[i] = "line " .. i
    end
    write(dir .. "/m.c", lines)
    local seen = {}
    local function rows()
      return table.concat(
        vim.tbl_map(function(row)
          return row + 1
        end, marks.rows(0)),
        " "
      )
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/m.c")
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      key("<leader>hl")()
      press("<Esc>")
      vim.api.nvim_win_set_cursor(0, { 10, 0 })
      press("Vjj")
      key("<leader>hl", "x")()
      seen.marked = rows()
      local mark = vim.api.nvim_buf_get_extmarks(0, -1, { 4, 0 }, { 4, -1 }, { details = true })[1]
      seen.colour = mark and mark[4].line_hl_group
      -- Lines put in above: the marks go down with their lines.
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2" })
      seen.moved = rows()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local visits = {}
      for _ = 1, 5 do
        key("<leader>hj")()
        visits[#visits + 1] = vim.fn.line(".")
      end
      seen.down = table.concat(visits, " ")
      key("<leader>hk")()
      seen.up = vim.fn.line(".")
      -- The same key on a marked line takes its mark off; on a selection that
      -- is all marked, every mark in it.
      vim.api.nvim_win_set_cursor(0, { 7, 0 })
      key("<leader>hl")()
      seen.one_off = rows()
      vim.api.nvim_win_set_cursor(0, { 12, 0 })
      press("Vjj")
      key("<leader>hl", "x")()
      seen.range_off = rows()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      key("<leader>hl")()
      key("<leader>hL")()
      seen.cleared = rows()
    end)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.marked == "5 10 11 12", "marked: " .. tostring(seen.marked))
    expect(seen.colour == "LineMark", "the line's colour: " .. tostring(seen.colour))
    expect(seen.moved == "7 12 13 14", "after two lines above: " .. tostring(seen.moved))
    expect(seen.down == "7 12 13 14 7", "<leader>hj went to " .. tostring(seen.down))
    expect(seen.up == 14, "<leader>hk went to " .. tostring(seen.up))
    expect(seen.one_off == "12 13 14", "after one taken off: " .. tostring(seen.one_off))
    expect(seen.range_off == "", "after the selection taken off: " .. tostring(seen.range_off))
    expect(seen.cleared == "", "after <leader>hL: " .. tostring(seen.cleared))
  end)

  -- The strip at the right edge shows where the marks of a file are: a line
  -- marked in both cells, a word lit and what the search finds in the right
  -- cell, the part in view lighter; <leader>uM puts it away and shows it
  -- again, and a click on it goes to the mark in that row.
  check("overview: the strip shows where the marks are, and a click goes there", function()
    local overview = require("taka.overview")
    local dir = temp_dir()
    local lines = {}
    for i = 1, 400 do
      lines[i] = i == 300 and "int needle;" or i == 100 and "int found_by_search;" or ("int plain_" .. i .. ";")
    end
    write(dir .. "/o.c", lines)
    local seen = {}
    local search, hlsearch = vim.fn.getreg("/"), vim.v.hlsearch
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/o.c")
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 200, 0 })
      require("taka.line_marks").toggle()
      vim.api.nvim_win_set_cursor(0, { 300, 4 })
      require("taka.words").toggle()
      vim.fn.setreg("/", "found_by_search")
      vim.v.hlsearch = 1
      vim.api.nvim_win_set_cursor(0, { 50, 0 })
      vim.cmd("normal! mq")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local strip = overview.strip(win)
      local height = #strip
      local function row(line)
        return math.min(height - 1, math.floor((line - 1) * height / 400)) + 1
      end
      seen.line = strip[row(200)]
      seen.word = strip[row(300)]
      seen.search = strip[row(100)]
      seen.mark = strip[row(50)]
      seen.cursor = strip[1][1]
      seen.top = strip[2][1]
      seen.plain = strip[row(250)]
      -- A click on the row of the word goes to its line.
      local mousepos = vim.fn.getmousepos
      vim.fn.getmousepos = function()
        return { winid = win, wincol = vim.api.nvim_win_get_width(win) - 1, winrow = row(300) }
      end
      local target_win, target_line = overview.target()
      seen.click = target_win == win and target_line
      -- Pressed on the strip and dragged, the window follows the mouse along
      -- it, to the top of the part each row stands for and not to its mark,
      -- also below the foot of the window; let go, a drag is a drag again.
      local top = vim.fn.win_screenpos(win)[1]
      local function at(screenrow)
        vim.fn.getmousepos = function()
          return { winid = win, wincol = 1, winrow = 1, screenrow = screenrow }
        end
      end
      local function line_after(keys)
        local before = vim.fn.line(".")
        press(keys)
        vim.wait(500, function()
          return vim.fn.line(".") ~= before
        end, 10)
        return vim.fn.line(".")
      end
      vim.fn.getmousepos = function()
        return {
          winid = win,
          wincol = vim.api.nvim_win_get_width(win) - 1,
          winrow = row(300),
          screenrow = top + row(300) - 1,
        }
      end
      seen.pressed = line_after("<LeftMouse>")
      at(top + row(100) - 1)
      seen.dragged = line_after("<LeftDrag>")
      seen.dragged_want = math.floor((row(100) - 1) * 400 / height) + 1
      at(top + height + 5)
      seen.below = line_after("<LeftDrag>")
      seen.below_want = math.floor((height - 1) * 400 / height) + 1
      press("<LeftRelease>")
      at(top + row(100) - 1)
      seen.released = line_after("<LeftDrag>")
      vim.fn.getmousepos = mousepos
      -- The colours follow those they are taken from, changed with no event:
      -- read once, the track kept a passing colour.
      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
      end
      local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine" })
      local number = vim.api.nvim_get_hl(0, { name = "CursorLineNr" })
      vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })
      vim.api.nvim_set_hl(0, "CursorLineNr", { fg = 0x654321 })
      overview.strip(win)
      seen.follows = bg("OverviewTrack") == 0x123456
        and bg("OverviewCursor") == 0x654321
        and bg("OverviewView") ~= 0x123456
      vim.api.nvim_set_hl(0, "CursorLine", cursorline)
      vim.api.nvim_set_hl(0, "CursorLineNr", number)
      key("<leader>uM")()
      seen.put_away = overview.strip(win) == nil
      key("<leader>uM")()
      seen.back = overview.strip(win) ~= nil
    end)
    vim.fn.setreg("/", search)
    vim.v.hlsearch = hlsearch
    require("taka.words").clear()
    reset_editor()
    expect(ok, tostring(err))
    expect(vim.deep_equal(seen.line, { "Overviewline", "Overviewline" }), "a line marked: " .. vim.inspect(seen.line))
    expect(seen.word and seen.word[2] == "OverviewWord1", "a word lit: " .. vim.inspect(seen.word))
    expect(seen.search and seen.search[2] == "Overviewsearch", "the search: " .. vim.inspect(seen.search))
    expect(seen.top == "OverviewView", "the part in view: " .. tostring(seen.top))
    expect(seen.cursor == "OverviewCursor", "the cursor's row: " .. tostring(seen.cursor))
    expect(seen.mark and seen.mark[2] == "Overviewmark", "a mark set with m: " .. vim.inspect(seen.mark))
    expect(
      vim.deep_equal(seen.plain, { "OverviewTrack", "OverviewTrack" }),
      "a row of nothing: " .. vim.inspect(seen.plain)
    )
    expect(seen.click == 300, "a click on the word's row goes to " .. tostring(seen.click))
    expect(seen.put_away and seen.back, "<leader>uM did not put it away and back")
    expect(seen.follows, "the strip's colours did not follow CursorLine and CursorLineNr")
    expect(seen.pressed == 300, "a press on the strip went to " .. tostring(seen.pressed))
    expect(
      seen.dragged == seen.dragged_want and seen.below == seen.below_want,
      ("dragged to %s and %s, not %s and %s"):format(seen.dragged, seen.below, seen.dragged_want, seen.below_want)
    )
    expect(seen.released == seen.below, "a drag after letting go moved to " .. tostring(seen.released))
  end)

  -- dm and a letter deletes the mark m and that letter set, and dm! every
  -- mark a to z of the file: :delmarks was the one way.
  check("marks: dm and a letter deletes that mark, dm! all of the file", function()
    -- lua/config/keymaps.lua is read on VeryLazy, which a headless start
    -- never reaches.
    if vim.fn.maparg("dm", "n") == "" then
      require("config.keymaps")
    end
    local dir = temp_dir()
    write(dir .. "/k.c", { "one", "two", "three", "four" })
    local seen = {}
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/k.c")
      local function mark(name, row)
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        press("m" .. name)
      end
      local function set()
        local out = {}
        for _, name in ipairs({ "a", "b", "c" }) do
          if vim.api.nvim_buf_get_mark(0, name)[1] > 0 then
            out[#out + 1] = name
          end
        end
        return table.concat(out)
      end
      mark("a", 1)
      mark("b", 2)
      mark("c", 3)
      seen.before = set()
      press("dmb")
      seen.one = set()
      seen.lines = #vim.api.nvim_buf_get_lines(0, 0, -1, false)
      press("dm!")
      seen.all = set()
    end)
    vim.notify = notify
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.before == "abc", "set: " .. tostring(seen.before))
    expect(seen.one == "ac", "after dmb: " .. tostring(seen.one))
    expect(seen.lines == 4, "dm deleted lines: " .. tostring(seen.lines))
    expect(seen.all == "", "after dm!: " .. tostring(seen.all))
  end)
end

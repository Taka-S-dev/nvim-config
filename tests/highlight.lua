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
end

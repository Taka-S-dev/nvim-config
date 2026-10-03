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

-- Debug lines put in and taken out by their mark (lua/taka/debug_lines.lua).
return function(T)
  local check, expect, temp_dir, need, reset_editor = T.check, T.expect, T.temp_dir, T.need, T.reset_editor

  -- The files known to hold debug lines are kept apart from the real ones.
  local store = temp_dir()
  require("taka.debug_lines").store = store

  -- The lines found, as file:line:kind.
  local function seen(dir, everywhere)
    local items
    require("taka.debug_lines").find(dir, function(found)
      items = found
    end, everywhere)
    vim.wait(10000, function()
      return items ~= nil
    end, 20)
    return table.concat(
      vim.tbl_map(function(item)
        return ("%s:%d:%s"):format(vim.fs.basename(item.filename), item.lnum, item.ai and "ai" or "hand")
      end, items or {}),
      " "
    )
  end

  local function bytes(path)
    local handle = assert(io.open(path, "rb"))
    local data = handle:read("*a")
    handle:close()
    return data
  end

  local function put(path, data)
    local handle = assert(io.open(path, "wb"))
    handle:write(data)
    handle:close()
  end

  -- A line is a debug line by the comment at its end alone: a DBG elsewhere on
  -- the line, a macro named DBG or a word that only starts with it is not.
  check("debug lines: a line is one by the mark at its end", function()
    local parse = require("taka.debug_lines").parse
    local function read(line)
      local mark = parse(line)
      return mark and ((mark.ai and "ai" or "hand") .. ":" .. mark.group .. (mark.n and ("#" .. mark.n) or ""))
        or "none"
    end
    local cases = {
      ['    printf("[DBG path-A 12]\\n"); /* DBG:path-A #12 */'] = "hand:path-A#12",
      ["    x = 1; /* DBG-AI #3 */"] = "ai:#3",
      ["    foo(a); /* DBG #4 */ \\"] = "hand:#4",
      ["    foo(a); \\ /* DBG #4 */"] = "hand:#4",
      ['    print("x") -- DBG #7'] = "hand:#7",
      ["    /* DBG 3 */"] = "none",
      ["    /* DBG # */"] = "none",
      ['    printf("x"); /* DBG */'] = "hand:",
      ['    printf("x"); /* DBG:path-A */  '] = "hand:path-A",
      ['    printf("x"); /* DBG-AI:p.1 */'] = "ai:p.1",
      ['    println("x") // DBG-AI'] = "ai:",
      ['    print("x") -- DBG:a'] = "hand:a",
      ["#ifdef DBG"] = "none",
      ['    printf("[DBG path-A] here\\n");'] = "none",
      ["    x = y - DBG"] = "none",
      ["    /* DBGFOO */"] = "none",
      ["    /* DBG:bad group */"] = "none",
    }
    for line, want in pairs(cases) do
      expect(read(line) == want, ("%q read as %s, not %s"):format(line, read(line), want))
    end
  end)

  -- <leader>di: the template chosen goes in below the cursor at the indent of
  -- the block it opens, carrying the group in its output and in its mark.
  check("debug lines: <leader>di puts the template in below, at the block's indent", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.cmd.edit(dir .. "/m.c")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int f(void)", "{", "\treturn 0;", "}" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local select = vim.ui.select
    vim.ui.select = function(items, _, choose)
      choose(items[1])
    end
    debug_lines.group = "path-A"
    local ok, err = pcall(debug_lines.insert)
    -- A second one, in a file outside any project: numbered past the first,
    -- from what the file holds.
    ok = ok and pcall(debug_lines.insert)
    vim.ui.select = select
    debug_lines.group = nil
    expect(ok, tostring(err))
    local line = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
    local want = '\tfprintf(stderr, "[DBG 1 path-A] %s:%d\\n", __FILE__, __LINE__); /* DBG:path-A #1 */'
    expect(line == want, "put in: " .. tostring(line))
    local second = vim.api.nvim_buf_get_lines(0, 3, 4, false)[1] or ""
    expect(second:find("[DBG 2 path-A]", 1, true) and second:find("/* DBG:path-A #2 */", 1, true), "then: " .. second)
    expect(vim.fn.line(".") == 4, "the cursor is on line " .. vim.fn.line("."))
    reset_editor()
  end)

  -- Put in after a blank line, a line takes the indent of the line below it,
  -- or, when that closes the block, of the last line with text above.
  check("debug lines: after a blank line, the indent comes from the lines around", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.cmd.edit(dir .. "/b.c")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "int f(int a)",
      "{",
      "    if (a) {",
      "        g();",
      "",
      "        return 1;",
      "    }",
      "    h();",
      "",
      "}",
    })
    local select, notify = vim.ui.select, vim.notify
    vim.ui.select = function(_, _, choose)
      choose({ text = "x();", kind = "template" })
    end
    vim.notify = function() end
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 9, 0 })
      debug_lines.insert()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      debug_lines.insert()
    end)
    vim.ui.select, vim.notify = select, notify
    expect(ok, tostring(err))
    local inside, before_close = vim.fn.getline(6), vim.fn.getline(11)
    expect(inside:match("^%s*") == "        ", "inside the block: " .. vim.inspect(inside))
    expect(before_close:match("^%s*") == "    ", "before the closing brace: " .. vim.inspect(before_close))
    reset_editor()
  end)

  -- A file whose changes not yet written are all debug lines is written, so a
  -- build straight after has them: a line put in, and lines just typed and
  -- then marked. One with a change of the reader's own is left to write, in
  -- an encoding of its own all the same.
  check("debug lines: the keys write a file whose only changes are debug lines", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    local sjis = vim.iconv("/* 日本語 */", "utf-8", "cp932")
    put(dir .. "/w.c", sjis .. "\r\nint f(void)\r\n{\r\n    return 0;\r\n}\r\n")
    vim.cmd.edit(dir .. "/w.c")
    local select, notify = vim.ui.select, vim.notify
    vim.ui.select = function(items, _, choose)
      choose(items[2])
    end
    vim.notify = function() end
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      debug_lines.insert()
      expect(
        bytes(dir .. "/w.c"):find('printf("[DBG 1] %s:%d\\n", __FILE__, __LINE__); /* DBG #1 */\r\n', 1, true),
        "put in, not written"
      )
      vim.api.nvim_buf_set_lines(0, 4, 4, false, { "    x();" })
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      vim.cmd("normal! V")
      debug_lines.mark_selection()
      expect(bytes(dir .. "/w.c"):find("    x(); /* DBG #2 */\r\n", 1, true), "marked, not written")
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { "int g;" })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      debug_lines.insert()
      expect(not bytes(dir .. "/w.c"):find("#3", 1, true), "written with the reader's change")
      expect(vim.bo.modified, "the buffer is not left to write")
    end)
    vim.ui.select, vim.notify = select, notify
    expect(ok, tostring(err))
    expect(bytes(dir .. "/w.c"):find(sjis, 1, true) == 1, "w.c is not in Shift-JIS")
    reset_editor()
  end)

  -- A line typed once is offered after in that project, the latest first,
  -- beside the templates and those set in vim.g.debug_line_templates; <C-x>
  -- in the list forgets it.
  check("debug lines: <leader>di offers the lines set and typed before, <C-x> forgets one", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.svn", "p")
    put(dir .. "/t.c", "int f(void)\n{\n    return 0;\n}\n")
    vim.cmd.edit(dir .. "/t.c")
    local select, input, notify, set = vim.ui.select, vim.ui.input, vim.notify, vim.g.debug_line_templates
    local offered
    local function choose(pick)
      vim.ui.select = function(items, opts, done)
        offered = vim.tbl_map(opts.format_item, items)
        done(pick(items))
      end
    end
    vim.notify = function() end
    vim.g.debug_line_templates = { c = { 'LOG_DEBUG("[{tag}]");' } }
    local ok, err = pcall(function()
      vim.ui.input = function(_, done)
        done('BIO_printf(bio_err, "[{tag}]\\n");')
      end
      choose(function(items)
        return items[#items]
      end)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      debug_lines.insert()
      expect(vim.fn.getline(3) == '    BIO_printf(bio_err, "[DBG 1]\\n"); /* DBG #1 */', "typed: " .. vim.fn.getline(3))
      choose(function(items)
        return items[4]
      end)
      debug_lines.insert()
      local want = {
        'fprintf(stderr, "[{tag}] %s:%d\\n", __FILE__, __LINE__);',
        'printf("[{tag}] %s:%d\\n", __FILE__, __LINE__);',
        'LOG_DEBUG("[{tag}]");',
        'BIO_printf(bio_err, "[{tag}]\\n");  (typed before; <C-x> forgets it)',
        "Type a line ({tag}, {n} and {where} are filled in)",
      }
      expect(vim.deep_equal(offered, want), "offered: " .. vim.inspect(offered))
      expect(
        vim.fn.getline(4) == '    BIO_printf(bio_err, "[DBG 2]\\n"); /* DBG #2 */',
        "chosen: " .. vim.fn.getline(4)
      )
      -- The list of a real start (the one Snacks puts in for vim.ui.select):
      -- <C-x> on the line typed forgets it, and the list opens again without
      -- it.
      vim.ui.select = Snacks.picker.select
      debug_lines.insert()
      local picker
      vim.wait(3000, function()
        picker = Snacks.picker.get({ source = "select" })[1]
        return picker and picker:count() == 5
      end, 20)
      expect(picker and picker:count() == 5, "the list: " .. tostring(picker and picker:count()))
      picker.list:view(4)
      picker:action("debug_line_forget")
      local again
      vim.wait(3000, function()
        again = Snacks.picker.get({ source = "select" })[1]
        return again and again ~= picker and again:count() == 4
      end, 20)
      expect(again and again:count() == 4, "after <C-x>: " .. tostring(again and again:count()))
      again:close()
    end)
    vim.ui.select, vim.ui.input, vim.notify, vim.g.debug_line_templates = select, input, notify, set
    expect(ok, tostring(err))
    reset_editor()
  end)

  -- While a choice is under the cursor in the list, the lines it would put in
  -- are shown below the line they go after, numbered and indented as they
  -- will be; another choice shows its own, and closing the list clears them.
  check("debug lines: the list shows below the line what the choice would put in", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.cmd.edit(dir .. "/p.c")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int f(void)", "{", "    return 0;", "}" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local buf, namespace = vim.api.nvim_get_current_buf(), vim.api.nvim_create_namespace("taka.debug_lines.preview")
    local function shown()
      local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
      local mark = marks[1]
      if not mark then
        return "none"
      end
      return (mark[2] + 1) .. ": " .. mark[4].virt_lines[1][1][1]
    end
    local select = vim.ui.select
    vim.ui.select = Snacks.picker.select
    local ok, err = pcall(function()
      debug_lines.insert()
      local picker
      vim.wait(3000, function()
        picker = Snacks.picker.get({ source = "select" })[1]
        return picker and shown() ~= "none"
      end, 20)
      local want = '2:     fprintf(stderr, "[DBG 1] %s:%d\\n", __FILE__, __LINE__); /* DBG #1 */'
      expect(shown() == want, "the first: " .. shown())
      picker.list:view(2)
      vim.wait(1000, function()
        return shown():find("    printf", 1, true) ~= nil
      end, 20)
      expect(shown():find('2:     printf("[DBG 1]', 1, true), "the second: " .. shown())
      picker.list:view(3)
      vim.wait(1000, function()
        return shown():find("goes here", 1, true) ~= nil
      end, 20)
      expect(shown() == "2:     (the line typed goes here) /* DBG #1 */", "the line typed: " .. shown())
      picker:close()
      vim.wait(1000, function()
        return shown() == "none"
      end, 20)
      expect(shown() == "none", "after closing: " .. shown())
    end)
    vim.ui.select = select
    expect(ok, tostring(err))
    expect(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 4, "a line was put in")
    reset_editor()
  end)

  -- The group set is the project's: it goes on the lines put in after, shows
  -- in the statusline beside the count, stays when the editor starts again,
  -- and the list is narrowed to it by typing it.
  check("debug lines: the group is kept with the project, shown, and filters the list", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.svn", "p")
    put(dir .. "/g.c", "int f(void)\n{\n    a(); /* DBG #1 */\n    return 0;\n}\n")
    local input, select, notify = vim.ui.input, vim.ui.select, vim.notify
    vim.notify = function() end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/g.c")
      vim.ui.input = function(_, done)
        done("gru1")
      end
      debug_lines.set_group()
      vim.wait(1000, function()
        return vim.g.debug_lines_count == "DBG 1 · gru1"
      end, 10)
      expect(vim.g.debug_lines_count == "DBG 1 · gru1", "statusline: " .. tostring(vim.g.debug_lines_count))
      -- As after a restart: nothing held but what was kept with the project.
      debug_lines.group = nil
      vim.ui.select = function(items, _, choose)
        choose(items[2])
      end
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      debug_lines.insert()
      local line = vim.fn.getline(3)
      expect(line:find("[DBG 2 gru1]", 1, true) and line:find("/* DBG:gru1 #2 */", 1, true), "put in: " .. line)
      vim.ui.select = Snacks.picker.select
      debug_lines.list()
      local list
      vim.wait(3000, function()
        list = Snacks.picker.get({ source = "qflist" })[1]
        return list and list:count() == 2 and not list:is_active()
      end, 20)
      expect(list and #list:items() == 2, "the list: " .. tostring(list and #list:items()))
      vim.api.nvim_buf_set_lines(list.input.win.buf, 0, -1, false, { "gru1" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = list.input.win.buf })
      vim.wait(1000, function()
        return list.matcher.pattern == "gru1" and not list:is_active()
      end, 10)
      local shown = vim.tbl_map(function(item)
        return item.line
      end, list:items())
      expect(#shown == 1 and shown[1]:find("[gru1]", 1, true) == 1, "filtered: " .. vim.inspect(shown))
      list:close()
    end)
    vim.ui.input, vim.ui.select, vim.notify = input, select, notify
    expect(ok, tostring(err))
    reset_editor()
  end)

  -- The count in the statusline: set on entering a file of the project, up
  -- by one for a line put in (a block counts once), gone once they are out.
  check("debug lines: the statusline counts the debug lines left", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.svn", "p")
    put(dir .. "/s.c", "int f(void)\n{\n    a(); /* DBG #1 */\n    b(); /* DBG #2 */\n    c(); /* DBG #2 */\n}\n")
    local function count()
      vim.wait(1000, function()
        return false
      end, 10)
      return tostring(vim.g.debug_lines_count)
    end
    local select, notify = vim.ui.select, vim.notify
    vim.notify = function() end
    vim.ui.select = function(items, _, choose)
      choose(items[1])
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/s.c")
      expect(count() == "DBG 2", "on entering: " .. count())
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      debug_lines.insert()
      expect(count() == "DBG 3", "after one put in: " .. count())
      debug_lines.remove({ dir .. "/s.c" }, function()
        return true
      end)
      debug_lines.refresh()
      expect(count() == "nil", "after all taken out: " .. count())
    end)
    vim.ui.select, vim.notify = select, notify
    expect(ok, tostring(err))
    reset_editor()
  end)

  -- Lines written as code and selected become one block of debug lines, with
  -- one number; a blank line and a line marked already are left alone.
  check("debug lines: <leader>di on a selection marks its lines with one number", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.cmd.edit(dir .. "/m.c")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "{",
      "    if (x) {",
      '        printf("[{tag}] x\\n");',
      "",
      "    }",
      "    y(); /* DBG #4 */",
      "}",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! Vjjjj")
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(debug_lines.mark_selection)
    vim.notify = notify
    expect(ok, tostring(err))
    local got = vim.api.nvim_buf_get_lines(0, 1, 6, false)
    local want = {
      "    if (x) { /* DBG #5 */",
      '        printf("[DBG 5] x\\n"); /* DBG #5 */',
      "",
      "    } /* DBG #5 */",
      "    y(); /* DBG #4 */",
    }
    expect(vim.deep_equal(got, want), "marked: " .. vim.inspect(got))
    -- In a macro: a line marked keeps its backslash last, and a line put in
    -- after one that continues continues too, so the macro is whole with the
    -- line in and with it taken out.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#define X(a) \\", "    foo(a); \\", "    bar(a)", "int y;" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! V")
    vim.notify = function() end
    ok, err = pcall(debug_lines.mark_selection)
    local select = vim.ui.select
    vim.ui.select = function(_, _, choose)
      choose({ text = "x(a);", kind = "template" })
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ok = ok and pcall(debug_lines.insert)
    vim.ui.select, vim.notify = select, notify
    expect(ok, tostring(err))
    got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    want = { "#define X(a) \\", "x(a); /* DBG #2 */ \\", "    foo(a); /* DBG #1 */ \\", "    bar(a)", "int y;" }
    expect(vim.deep_equal(got, want), "in a macro: " .. vim.inspect(got))
    reset_editor()
  end)

  -- The list counts a block of one number as one debug line, at its first
  -- line; a line with no number stands alone, and the same number in another
  -- file is another entry.
  check("debug lines: the lines of one number are one entry in the list", function()
    local function item(file, lnum, n)
      return { filename = file, lnum = lnum, n = n, text = file .. lnum, ai = false, group = "" }
    end
    local entries = require("taka.debug_lines").blocks({
      item("a.c", 3, 4),
      item("a.c", 4, 5),
      item("a.c", 5, 5),
      item("a.c", 9),
      item("a.c", 10),
      item("b.c", 2, 5),
    })
    local got = vim.tbl_map(function(entry)
      return ("%s:%d-%d x%d"):format(entry.filename, entry.lnum, entry.end_lnum, entry.count)
    end, entries)
    local want = { "a.c:3-3 x1", "a.c:4-5 x2", "a.c:9-9 x1", "a.c:10-10 x1", "b.c:2-2 x1" }
    expect(vim.deep_equal(got, want), "entries: " .. vim.inspect(got))
  end)

  -- <C-x> in the list takes out the entry under the cursor: every line of its
  -- number, and no other; the list opens again with what is left.
  check("debug lines: <C-x> in the list takes the entry's lines out", function()
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.svn", "p")
    put(dir .. "/m.c", "{\n  a(); /* DBG #4 */\n  b(); /* DBG #5 */\n  c(); /* DBG #5 */\n  d(); /* DBG */\n}\n")
    vim.cmd.edit(dir .. "/m.c")
    local debug_lines = require("taka.debug_lines")
    local notify = vim.notify
    vim.notify = function() end
    local function picker()
      vim.wait(3000, function()
        local open = Snacks.picker.get({ source = "qflist" })[1]
        return open and open:count() > 0
      end, 20)
      return Snacks.picker.get({ source = "qflist" })[1]
    end
    debug_lines.list()
    local list = picker()
    local ok, err = pcall(function()
      expect(list and list:count() == 3, "entries: " .. tostring(list and list:count()))
      local mapped = vim.api.nvim_buf_call(list.input.win.buf, function()
        return vim.fn.maparg("<C-x>", "i", false, true)
      end)
      expect(mapped.desc == "Take the debug line out", "<C-x> in the input: " .. vim.inspect(mapped.desc))
      list.list:view(2)
      list:action("debug_line_out")
      vim.wait(3000, function()
        local again = Snacks.picker.get({ source = "qflist" })[1]
        return again and again ~= list and again:count() == 2
      end, 20)
      local again = Snacks.picker.get({ source = "qflist" })[1]
      expect(again and again:count() == 2, "after: " .. tostring(again and again:count()))
      again:close()
    end)
    vim.notify = notify
    expect(ok, tostring(err))
    local got = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|")
    expect(got == "{|  a(); /* DBG #4 */|  d(); /* DBG */|}", "m.c: " .. got)
    expect(bytes(dir .. "/m.c") == "{\n  a(); /* DBG #4 */\n  d(); /* DBG */\n}\n", "m.c was not written")
    reset_editor()
  end)

  -- From a line of a log, the debug line it names, however the lines moved:
  -- the number is found nearest the cursor, and looked for in every file when
  -- the file is not known.
  check("debug lines: <leader>dj goes from a log line to the debug line it names", function()
    need("rg")
    local debug_lines = require("taka.debug_lines")
    expect(debug_lines.number_in("x [DBG p 3] y [DBG-AI 12] z", 20) == 12, "the nearest number")
    expect(debug_lines.number_in("[DBG 12 path-A] a.c:3", 1) == 12, "the number first, as printed now")
    expect(debug_lines.number_in("[DBG-AI 7 p] x", 1) == 7, "an agent's, the number first")
    expect(debug_lines.number_in("[DBG x1] [DBG 7]", 1) == 7, "a group's digit is no number")
    expect(debug_lines.number_in("[DBG path-A]", 1) == nil, "a tag with no number")
    expect(debug_lines.number_in("[DBG p 9] a.c:2", 1) == 9, "the older order, the number last")
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.svn", "p")
    -- In a macro, its mark before the backslash: ripgrep finds it there too.
    put(dir .. "/a.c", "#define X \\\n    w(); \\\n    x(); /* DBG:p #9 */ \\\n    y()\n")
    vim.api.nvim_set_current_dir(dir)
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "run: [DBG p 9] a.c:2" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    -- A number not read from the line would be asked for: that is a failure
    -- here, not a wait.
    local input, asked = vim.ui.input, false
    vim.ui.input = function()
      asked = true
    end
    debug_lines.jump()
    vim.ui.input = input
    expect(not asked, "the number was not read from the log line")
    vim.wait(10000, function()
      return vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "a.c"
    end, 20)
    expect(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "a.c", "went to " .. vim.api.nvim_buf_get_name(0))
    expect(vim.fn.line(".") == 3 and vim.fn.col(".") == 5, ("at %d:%d"):format(vim.fn.line("."), vim.fn.col(".")))
    reset_editor()
  end)

  -- Outside a project nothing is searched: from the home folder the list went
  -- through all of it and took long to come.
  check("debug lines: <leader>dl outside a project says so and searches nothing", function()
    local said
    local notify = vim.notify
    vim.notify = function(message)
      said = message
    end
    vim.cmd.enew()
    local ok, err = pcall(require("taka.debug_lines").list)
    vim.notify = notify
    expect(ok, tostring(err))
    expect(said and said:find("Not in a project", 1, true), "said: " .. tostring(said))
    reset_editor()
  end)

  -- Taking lines out leaves the others, writes the file back in its own
  -- encoding, line ends and last line, and does not write a file open with
  -- changes of the reader's own; a line put in and not written is found.
  check("debug lines: found in files and buffers, taken out by kind, files kept as they were", function()
    need("rg")
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    local sjis = vim.iconv("/* 日本語 */", "utf-8", "cp932")
    put(dir .. "/a.c", sjis .. "\r\nint a;\r\nint b; /* DBG:x */\r\nint c; /* DBG-AI:y */\r\n#ifdef DBG\r\n#endif")
    put(dir .. "/b.c", "int d; /* DBG-AI */\n")
    vim.cmd.edit(dir .. "/b.c")
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "int e; /* DBG */", "int f;" })
    -- Not known yet: only the file open is read, until every file is searched,
    -- which makes both known.
    local open = seen(dir)
    expect(open == "b.c:1:hand b.c:3:ai", "found in the open file: " .. open)
    local all = seen(dir, true)
    expect(all == "a.c:3:hand a.c:4:ai b.c:1:hand b.c:3:ai", "found in every file: " .. all)
    local known = seen(dir)
    expect(known == all, "found in the files known: " .. known)
    local removed, unsaved = debug_lines.remove({ dir .. "/a.c", dir .. "/b.c" }, function(mark)
      return mark.ai
    end)
    expect(removed == 2, removed .. " taken out")
    expect(#unsaved == 1 and vim.fs.basename(unsaved[1]) == "b.c", "left to write: " .. vim.inspect(unsaved))
    local a = bytes(dir .. "/a.c")
    expect(a == sjis .. "\r\nint a;\r\nint b; /* DBG:x */\r\n#ifdef DBG\r\n#endif", "a.c became " .. vim.inspect(a))
    expect(bytes(dir .. "/b.c") == "int d; /* DBG-AI */\n", "b.c was written with the reader's changes")
    expect(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") == "int e; /* DBG */|int f;", "b.c's buffer")
    -- A file read with no lines left is let go of: a mark written into it
    -- afterwards is seen only by searching every file.
    debug_lines.remove({ dir .. "/a.c" }, function()
      return true
    end)
    expect(seen(dir) == "b.c:1:hand", "after a.c was emptied: " .. seen(dir))
    put(dir .. "/a.c", "int z; /* DBG */\n")
    expect(seen(dir) == "b.c:1:hand", "a.c is still known: " .. seen(dir))
    expect(seen(dir, true) == "a.c:1:hand b.c:1:hand", "every file: " .. seen(dir, true))
    reset_editor()
  end)

  -- A file open in another editor, found by its swap file: with no changes
  -- there it is written as ever; with changes not written there, a line is
  -- not put in and lines are not taken out, as that editor would lose them
  -- when it writes or find the file changed under it.
  check("debug lines: a file with changes not written in another editor is left alone", function()
    local debug_lines = require("taka.debug_lines")
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.svn", "p")
    local file = dir .. "/o.c"
    put(file, "int f(void)\n{\n    return 0; /* DBG-AI #1 */\n}\n")
    local swaps = vim.fs.normalize(vim.fn.stdpath("state") .. "/swap")
    local function other(command)
      -- A plain Neovim with the file open and its swap file where this one
      -- looks, kept running until it is stopped.
      return vim.system({
        vim.v.progpath,
        "--clean",
        "--headless",
        "--cmd",
        "set directory=" .. swaps .. "//",
        "-c",
        command,
        "-c",
        "sleep 30",
        file,
      })
    end
    -- The swap files of o.c alone, by the name Neovim gives them: the full
    -- path with each separator and colon made a %. Nothing else in the folder
    -- is looked at or removed, as it holds the swap files of real work.
    local prefix = vim.fn.fnamemodify(file, ":p"):gsub("[:/\\]", "%%"):lower()
    local function swaps_of_file()
      local found = {}
      for name in vim.fs.dir(swaps) do
        if name:lower():sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^%.sw.$") then
          found[#found + 1] = swaps .. "/" .. name
        end
      end
      return found
    end
    local function wait_for_swap()
      vim.wait(5000, function()
        for _, swap in ipairs(swaps_of_file()) do
          local info = vim.fn.swapinfo(swap)
          if info.pid and info.pid ~= vim.fn.getpid() then
            return true
          end
        end
        return false
      end, 50)
    end
    local function agent(call)
      local result = vim
        .system({ vim.v.progpath, "--headless", "+lua require('taka.debug_lines').cli" .. call, "+qa" }, {
          cwd = dir,
          text = true,
          env = { DEBUG_LINES_STORE = store, SHELL = "" },
        })
        :wait(60000)
      return result.code, result.stdout or ""
    end
    local running = {}
    local function stop()
      for _, process in ipairs(running) do
        process:kill(9)
        process:wait()
      end
      running = {}
    end
    local ok, err = pcall(function()
      -- Open with no change: written as ever, and no page about the swap file.
      running[1] = other("echo")
      wait_for_swap()
      local code, said = agent("{'add', 'o.c', '2'}")
      stop()
      expect(code == 0 and not said:find("swap file", 1, true), "with the file open there: " .. said)
      -- Open with a change not written: nothing written, and the reason given.
      local before = bytes(file)
      running[1] = other("normal! Gox")
      wait_for_swap()
      code, said = agent("{'add', 'o.c', '1'}")
      local removed, _, skipped = debug_lines.remove({ file }, function()
        return true
      end)
      stop()
      expect(code == 1 and said:find("changes not written in another editor", 1, true), "add: " .. said)
      expect(removed == 0 and #skipped == 1, ("took %d out, skipped %d"):format(removed, #skipped))
      expect(bytes(file) == before, "o.c was written")
    end)
    stop()
    for _, swap in ipairs(swaps_of_file()) do
      os.remove(swap)
    end
    expect(ok, tostring(err))
  end)

  -- The command line an agent uses, run as an agent runs it: a line put in
  -- after the one given, in the file's encoding, and clear taking out the
  -- agent's lines and none put in by hand.
  check("debug lines: an agent puts lines in and takes only its own out", function()
    need("rg")
    local dir = temp_dir()
    local sjis = vim.iconv("/* 日本語 */", "utf-8", "cp932")
    local original = sjis .. "\r\nint f(int x)\r\n{\r\n    return x; /* DBG */\r\n}\r\n"
    put(dir .. "/a.c", original)
    -- A working copy, as list and clear look only inside a project.
    vim.fn.mkdir(dir .. "/.svn", "p")
    local function agent(call, text)
      local result = vim
        .system({ vim.v.progpath, "--headless", "+lua require('taka.debug_lines').cli" .. call, "+qa" }, {
          cwd = dir,
          text = true,
          env = { DEBUG_LINE_TEXT = text, DEBUG_LINES_STORE = store, SHELL = "" },
        })
        :wait(60000)
      return result.code, result.stdout or ""
    end
    local code, said = agent("{'add', 'a.c', '3', 'p'}")
    expect(code == 0, "add failed: " .. said)
    local want = '    fprintf(stderr, "[DBG-AI 1 p] %s:%d\\n", __FILE__, __LINE__); /* DBG-AI:p #1 */'
    expect(said:find("a.c:4: " .. want, 1, true), "add said: " .. said)
    local after = bytes(dir .. "/a.c")
    expect(after:find(sjis, 1, true) == 1 and after:find(want .. "\r\n", 1, true), "a.c became " .. vim.inspect(after))
    code, said = agent("{'add', 'a.c', '1'}", "x = 1;\n  y = 2;")
    expect(code == 0 and said:find("a.c:3:   y = 2; /* DBG-AI #2 */", 1, true), "a typed block: " .. said)
    -- Listed from the file the agent put lines in, which is then known; a mark
    -- in a file it never touched is not looked for.
    put(dir .. "/other.c", "int w; /* DBG-AI */\n")
    code, said = agent("{'list'}")
    expect(code == 0 and said:find("4 debug lines", 1, true) and not said:find("other.c", 1, true), "list: " .. said)
    code, said = agent("{'add', 'a.c', '99'}")
    expect(code == 1 and said:find("error: line 99", 1, true), "a line past the end: " .. code .. " " .. said)
    code, said = agent("{'clear'}")
    expect(code == 0 and said:find("3 debug lines taken out", 1, true), "clear said: " .. said)
    expect(bytes(dir .. "/a.c") == original, "a.c is not as it was: " .. vim.inspect(bytes(dir .. "/a.c")))
    expect(bytes(dir .. "/other.c") == "int w; /* DBG-AI */\n", "other.c was changed")
    -- A number is not given again once its lines are gone, so an old log
    -- does not lead to a line put in since.
    code, said = agent("{'add', 'a.c', '0'}", "z();")
    expect(code == 0 and said:find("/* DBG-AI #3 */", 1, true), "after clear: " .. said)
  end)
end

-- Sources in Shift-JIS searched and shown as the editor shows them
-- (lua/taka/lib/legacy_text.lua, lua/taka/grep_encoding.lua).
return function(T)
  local check, expect, temp_dir, reset_editor = T.check, T.expect, T.temp_dir, T.reset_editor

  local function sjis(text)
    return vim.iconv(text, "utf-8", "cp932")
  end

  local function write(path, bytes)
    local handle = assert(io.open(path, "wb"))
    handle:write(bytes)
    handle:close()
  end

  check("encoding: bytes are told apart and shown as the editor shows them", function()
    local legacy = require("taka.lib.legacy_text")
    local raw = sjis("/* 日本語 */ int a;")
    expect(legacy.is_utf8("日本語 abc"), "UTF-8 not taken for UTF-8")
    expect(not legacy.is_utf8(raw), "cp932 taken for UTF-8")
    local text, converted = legacy.text(raw)
    expect(text == "/* 日本語 */ int a;" and converted, "the line: " .. text)
    local same, untouched = legacy.text("日本語")
    expect(same == "日本語" and not untouched, "UTF-8 was converted")
    -- Neither UTF-8 nor cp932: a lead byte with nothing after it.
    local broken, changed = legacy.text("abc\129")
    expect(broken == "abc\129" and not changed, "bytes that are neither were changed")
    -- 3 bytes of ASCII and 6 of Japanese come before `int`: 9 in cp932, 12 in UTF-8.
    expect(
      legacy.column(sjis("/* 日本語 int"), 9) == 12,
      "the column: " .. legacy.column(sjis("/* 日本語 int"), 9)
    )
    local lines, whole = legacy.lines({ "int a;", sjis("/* 語 */") })
    expect(whole and lines[1] == "int a;" and lines[2] == "/* 語 */", "the lines of a file")

    local word = [[(?:語|(?-iu:\x8c\xea))]]
    expect(legacy.pattern("語", false) == word, "a character: " .. legacy.pattern("語", false))
    expect(legacy.pattern("a+", false) == "a+", "ASCII changed")
    expect(legacy.pattern("[語]", false) == "[語]", "a class changed")
    expect(legacy.pattern([[\.]], false) == [[\.]], "an escaped dot changed")
    expect(legacy.pattern("語(", true) == word .. [[\(]], "fixed: " .. legacy.pattern("語(", true))
    expect(select(2, legacy.pattern("a(", true)) == false, "fixed ASCII changed")
    -- A character cp932 does not have is searched for as it is.
    expect(legacy.pattern("😀", false) == "😀", "an emoji: " .. legacy.pattern("😀", false))
  end)

  check("encoding: a grep finds both encodings and reads as the files do", function()
    local dir = temp_dir()
    write(dir .. "/s.c", sjis("/* 日本語のコメント */\nint alpha; /* 説明 */ int omega;\n"))
    write(dir .. "/big.c", sjis("アABC\n"))
    write(dir .. "/small.c", sjis("アabc\n"))
    write(dir .. "/u.c", "/* 日本語のコメント utf8 */\n")
    local picker
    local function search(text, opts)
      if picker then
        picker:close()
        vim.wait(50)
      end
      picker = Snacks.picker.grep(vim.tbl_extend("force", { cwd = dir, search = text, live = false }, opts or {}))
      vim.wait(300)
      vim.wait(5000, function()
        return not picker:is_active()
      end, 20)
      vim.wait(100)
      local out = {}
      for _, item in ipairs(picker:items()) do
        Snacks.picker.util.resolve(item)
        out[vim.fs.basename(item.file)] = item
      end
      return out
    end
    local japanese = search("日本語")
    local ascii = search("alpha")
    local after = search("omega")
    local across = search("alpha.*omega")
    local literal = search("語の", { regex = false })
    local only_utf8 = search("日本語 -- -g u.c")
    local lower = search("アabc")
    local capital = search("アABC")
    -- The preview of the file in Shift-JIS, opened on its row.
    local found = search("説明")
    vim.wait(500)
    local preview = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false)
    picker:close()
    reset_editor()

    local s, u = japanese["s.c"], japanese["u.c"]
    expect(s and u, "the hits: " .. vim.inspect(vim.tbl_keys(japanese)))
    expect(s.line == "/* 日本語のコメント */", "the line: " .. tostring(s.line))
    expect(s.pos[2] == 3, "the column of a hit in Shift-JIS: " .. s.pos[2])
    expect(s.positions and #s.positions == 9 and s.positions[1] == 4, "the letters lit: " .. vim.inspect(s.positions))
    expect(s.line:sub(s.positions[1], s.positions[#s.positions]) == "日本語", "lit wrong")
    expect(u.line == "/* 日本語のコメント utf8 */", "the line in UTF-8: " .. tostring(u.line))
    expect(ascii["s.c"].line == "int alpha; /* 説明 */ int omega;", "found by ASCII: " .. tostring(ascii["s.c"].line))
    local late = after["s.c"]
    expect(late.pos[2] == 28, "the column after Japanese: " .. late.pos[2])
    expect(late.line:sub(late.positions[1], late.positions[#late.positions]) == "omega", "lit after Japanese")
    expect(across["s.c"] ~= nil, "a dot did not go across Japanese")
    expect(literal["s.c"] and literal["u.c"], "the text as it is")
    expect(only_utf8["u.c"] and not only_utf8["s.c"], "the options after -- were lost")
    expect(lower["big.c"] and lower["small.c"], "smart case, typed in small letters")
    expect(capital["big.c"] and not capital["small.c"], "smart case, typed in capitals")
    expect(found["s.c"] ~= nil, "nothing to preview")
    expect(preview[1] == "/* 日本語のコメント */", "the preview: " .. tostring(preview[1]))
  end)

  check("encoding: :grep results read as the files do", function()
    local dir = temp_dir()
    write(dir .. "/q.c", sjis("/* 語 */ int zeta;\n"))
    vim.cmd.cd(dir)
    vim.cmd("silent grep! zeta")
    local item = vim.fn.getqflist()[1]
    local text, col = item and item.text, item and item.col
    vim.fn.setqflist({}, "r")
    reset_editor()
    expect(text == "/* 語 */ int zeta;", "the text: " .. tostring(text))
    expect(col == 15, "the column: " .. tostring(col))
  end)

  check("encoding: the lists read from files in Shift-JIS read as the files do", function()
    local dir = temp_dir()
    write(dir .. "/d.c", sjis('printf("語"); /* DBG #1 */\nvoid f(void) { /* 語 */ count = 1; }\n'))

    local debug_lines = require("taka.debug_lines")
    local kept_store = debug_lines.store
    debug_lines.store = temp_dir()
    local marks
    debug_lines.find(dir, function(found)
      marks = found
    end, true)
    vim.wait(10000, function()
      return marks ~= nil
    end, 20)
    debug_lines.store = kept_store

    local writes
    require("taka.writes").find("count", dir, function(items)
      writes = items
    end)
    vim.wait(10000, function()
      return writes ~= nil
    end, 20)

    local trace = dir .. "/t.jsonl"
    write(trace, vim.json.encode({ title = "t", root = dir }) .. "\n" .. vim.json.encode({
      id = "a",
      file = "d.c",
      line = 2,
      text = "/* 語 */ count",
      title = "x",
    }) .. "\n")
    local _, problems = require("taka.trace").check(trace)
    reset_editor()

    expect(
      marks and marks[1] and marks[1].text == 'printf("語"); /* DBG #1 */',
      "the debug line: " .. vim.inspect(marks)
    )
    local write_item = writes and writes[1]
    expect(
      write_item and write_item.text == "void f(void) { /* 語 */ count = 1; }",
      "the write: " .. vim.inspect(writes)
    )
    expect(write_item and write_item.col == 26, "the column of the write: " .. tostring(write_item and write_item.col))
    expect(problems == 0, "the text of a trace step was not found: " .. tostring(problems))
  end)
end

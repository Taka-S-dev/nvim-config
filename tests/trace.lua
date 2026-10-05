-- The trace (lua/taka/trace/).
return function(T)
  local check, expect, temp_dir, write, key, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.key, T.reset_editor

  local store = require("taka.trace.store")
  local real_dir = store.dir

  -- The traces are read from a folder of their own for the checks, never from
  -- the one in Neovim's data directory.
  local function trace_folder()
    local dir = temp_dir()
    store.dir = function()
      return dir
    end
    return dir
  end

  local function lines_of(records)
    return vim.tbl_map(function(record)
      return type(record) == "string" and record or vim.json.encode(record)
    end, records)
  end

  -- A trace is written a line at a time by something else, so it is read as it
  -- comes: the header gives the title and the folder the paths are under, a
  -- step goes under the step it names, and a line half written is left out.
  check("trace: read as written, each step under the one it names", function()
    local dir = temp_dir()
    local path = dir .. "/t.jsonl"
    write(
      path,
      lines_of({
        { title = "Why it fails", root = dir .. "/src" },
        { id = "a", file = "a.c", line = 3, title = "Enters", note = { "first", "second" } },
        { id = "b", file = "b.c", line = 9, note = "Writes len\nthen returns", kind = "cause" },
        { parent = "a", file = dir .. "/src/a.c", line = 5, title = "Under a" },
        -- The same id again, and a parent that is not there.
        { id = "a", parent = "nowhere", file = "c.c", line = 1, title = "Again" },
        '{"file": "d.c", "line": 4, "tit',
      })
    )
    -- With a byte order mark, as some editors and shells write UTF-8.
    local written = vim.fn.readfile(path)
    written[1] = "\239\187\191" .. written[1]
    vim.fn.writefile(written, path)
    local trace = store.read(path)
    local seen = vim.tbl_map(function(row)
      return ("%d.%d %s %s:%d"):format(
        row.number,
        row.depth,
        row.step.title,
        vim.fs.basename(row.step.file),
        row.step.line
      )
    end, store.outline(trace))
    expect(trace.title == "Why it fails", "title: " .. trace.title)
    expect(
      vim.deep_equal(seen, {
        "1.0 Enters a.c:3",
        "2.1 Under a a.c:5",
        "3.0 Writes len b.c:9",
        "4.0 Again c.c:1",
      }),
      "outline: " .. vim.inspect(seen)
    )
    expect(trace.steps[1].note == "first\nsecond", "a note given as a list: " .. trace.steps[1].note)
    expect(trace.steps[1].file == vim.fs.normalize(dir .. "/src/a.c"), "path: " .. trace.steps[1].file)
  end)

  -- In the code, each step has its number in the sign column and its title in
  -- a line above it, and the step chosen its note below the title too, every
  -- step with <leader>uR; ]n goes from step to step, and a step written while
  -- the trace is shown turns up without anything pressed.
  check("trace: steps drawn above their lines, followed with ]n, and added as written", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/main.c", { "int main(void)", "{", "    int len = parse();", "    return len;", "}" })
    write(code .. "/parse.c", { "int parse(void)", "{", "    return -1;", "}" })
    local path = folder .. "/bug.jsonl"
    write(
      path,
      lines_of({
        { title = "len goes negative", root = code },
        { file = "main.c", line = 3, title = "Takes len", note = "len is used as a size" },
        { file = "parse.c", line = 3, title = "Returns -1", note = "on every input", kind = "cause" },
      })
    )
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/main.c")
      expect(trace.open(), "the newest trace was not found")
      local function marks(buf)
        local out = {}
        local namespace = vim.api.nvim_get_namespaces().config_trace
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
          local details = mark[4]
          local text = {}
          for _, virt in ipairs(details.virt_lines or {}) do
            local parts = {}
            for _, chunk in ipairs(virt) do
              parts[#parts + 1] = chunk[1]
            end
            text[#text + 1] = vim.trim(table.concat(parts))
          end
          out[#out + 1] = ("%d [%s] %s"):format(
            mark[2] + 1,
            vim.trim(details.sign_text or ""),
            table.concat(text, " | ")
          )
        end
        return out
      end
      seen.main = marks(0)
      key("]n")()
      seen.first = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      key("]n")()
      seen.second = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      seen.parse = marks(0)
      -- A step written to the end of the file while it is shown.
      local file = assert(io.open(path, "a"))
      file:write(vim.json.encode({ file = "parse.c", line = 1, title = "Declared here", note = "a prototype" }) .. "\n")
      file:close()
      vim.wait(3000, function()
        return #trace.state().rows == 3
      end, 20)
      seen.added = marks(0)
      trace.show_all_notes(true)
      seen.all = marks(0)
      trace.show_all_notes(false)
      -- <leader>uR puts every note away, the numbers kept, and shows them again.
      key("<leader>uR")()
      seen.hidden = marks(0)
      key("<leader>uR")()
      seen.shown_again = marks(0)
    end)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(vim.deep_equal(seen.main, { "3 [1] ▎ 1 Takes len …" }), "main.c: " .. vim.inspect(seen.main))
    expect(
      seen.first == "main.c:3" and seen.second == "parse.c:3",
      ("]n went to %s, then %s"):format(seen.first, seen.second)
    )
    expect(
      vim.deep_equal(seen.parse, { "3 [2] ▎ 2  Returns -1 | ▎  on every input" }),
      "parse.c: " .. vim.inspect(seen.parse)
    )
    expect(
      vim.deep_equal(seen.added, { "1 [3] ▎ 3 Declared here …", "3 [2] ▎ 2  Returns -1 | ▎  on every input" }),
      "added: " .. vim.inspect(seen.added)
    )
    expect(
      vim.deep_equal(
        seen.all,
        { "1 [3] ▎ 3  Declared here | ▎  a prototype", "3 [2] ▎ 2  Returns -1 | ▎  on every input" }
      ),
      "every note: " .. vim.inspect(seen.all)
    )
    expect(vim.deep_equal(seen.hidden, { "1 [3] ", "3 [2] " }), "put away: " .. vim.inspect(seen.hidden))
    expect(vim.deep_equal(seen.shown_again, seen.added), "shown again: " .. vim.inspect(seen.shown_again))
  end)

  -- The panel lists the steps as a tree, and moving its cursor shows each step
  -- in the window beside it, the cursor staying in the panel.
  check("trace: the panel shows the step its cursor is on", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/a.c", { "int a;", "int b;", "int c;" })
    write(code .. "/lib/b.c", { "int d;", "int e;" })
    write(
      folder .. "/t.jsonl",
      lines_of({
        { title = "Panel", root = code },
        { id = "1", file = "a.c", line = 2, title = "In a" },
        { parent = "1", file = "lib/b.c", line = 2, title = "Then b", kind = "suspect" },
        { file = "a.c", line = 3, title = "Back in a" },
        { file = "a.c", line = 1, title = "Still in a" },
      })
    )
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/a.c")
      local code_win = vim.api.nvim_get_current_win()
      key("<leader>ja")()
      vim.wait(1000, function()
        return #require("taka.trace.panel").lines() == 4
      end, 20)
      seen.rows = require("taka.trace.panel").lines()
      local picker = Snacks.picker.get({ source = "trace" })[1]
      picker.list:view(2)
      vim.wait(1000, function()
        return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)):match("b%.c$") ~= nil
      end, 20)
      seen.shown = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)), ":t")
        .. ":"
        .. vim.api.nvim_win_get_cursor(code_win)[1]
      seen.stayed = vim.api.nvim_get_current_win() ~= code_win
    end)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(
      -- A row names its file only where it is not the file of the row above.
      seen.rows
        and seen.rows[1] == " 1 In a  @a.c:2"
        and seen.rows[2]:match("^└╴ 2 .+Then b  @b%.c:2$")
        and seen.rows[3] == " 3 Back in a  @a.c:3"
        and seen.rows[4] == " 4 Still in a  @:1",
      "rows: " .. vim.inspect(seen.rows)
    )
    expect(seen.shown == "b.c:2", "the code window shows " .. tostring(seen.shown))
    expect(seen.stayed, "the cursor left the panel")
  end)

  -- A step that gives the text of its line is found by it once the code has
  -- moved, or its line number was written wrong; one whose text is nowhere is
  -- marked, not shown on a line it does not mean. A step is copied with its
  -- place, to ask about it.
  check("trace: a step is found by its line's text, marked when lost, and copied", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    -- Two lines were added at the top since the trace was written.
    write(code .. "/s.c", {
      "/* new */",
      "/* new */",
      "int main(void)",
      "{",
      "\tint len = parse(buf);",
      "\treturn len;",
      "}",
    })
    write(
      folder .. "/moved.jsonl",
      lines_of({
        { title = "Moved", root = code },
        { file = "s.c", line = 3, title = "Parses", text = "int len =   parse(buf);" },
        { file = "s.c", line = 4, title = "Gone", text = "free(buf);" },
        { file = "s.c", line = 1, title = "No text" },
      })
    )
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/s.c")
      expect(trace.open(), "the trace was not found")
      local namespace = vim.api.nvim_get_namespaces().config_trace
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })) do
        local first = {}
        for _, chunk in ipairs(mark[4].virt_lines[1]) do
          first[#first + 1] = chunk[1]
        end
        seen[#seen + 1] = ("%d %s %s"):format(mark[2] + 1, mark[4].sign_hl_group, vim.trim(table.concat(first)))
      end
      key("]n")()
      seen.cursor = vim.fn.line(".")
      trace.yank({ trace.state().rows[1] })
      seen.copied = vim.fn.getreg('"')
    end)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    table.sort(seen)
    expect(
      vim.deep_equal({ seen[1], seen[2], seen[3] }, {
        "1 TraceStep ▎ 3 No text",
        "4 TraceLost ▎ 2 Gone  (line not found)",
        "5 TraceStep ▎ 1 Parses",
      }),
      "marks: " .. vim.inspect(seen)
    )
    expect(seen.cursor == 5, "]n went to line " .. tostring(seen.cursor))
    expect(seen.copied == 'Trace "moved" step 1/3: Parses (s.c:5)', "copied: " .. tostring(seen.copied))
  end)

  -- The stored traces are listed as the other lists are, and <C-x> deletes
  -- one, after asking: a trace is a file, gone once deleted.
  check("trace: <C-x> in the list of traces deletes one", function()
    local folder = trace_folder()
    for _, name in ipairs({ "old", "new" }) do
      write(folder .. "/" .. name .. ".jsonl", lines_of({ { title = name } }))
    end
    local seen = {}
    local picker
    local ok, err = pcall(function()
      key("<leader>jA")()
      picker = Snacks.picker.get({ source = "trace_files" })[1]
      expect(picker, "the list did not open")
      vim.wait(1000, function()
        return #picker:items() == 2
      end, 20)
      seen.before = #picker:items()
      seen.mapped = vim.tbl_contains(
        vim.tbl_map(function(map)
          return map.lhs
        end, vim.api.nvim_buf_get_keymap(picker.input.win.buf, "i")),
        "<C-X>"
      )
      local target = picker:current().title
      picker:action("trace_delete")
      vim.wait(1000, function()
        return #picker:items() == 1
      end, 20)
      seen.after = #picker:items()
      seen.gone = vim.fn.filereadable(folder .. "/" .. target .. ".jsonl") == 0
      seen.open = not picker.closed
    end)
    if picker and not picker.closed then
      picker:close()
    end
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(seen.mapped, "<C-x> is not a key of the list")
    expect(seen.before == 2 and seen.after == 1, ("%s traces, then %s"):format(seen.before, seen.after))
    expect(seen.gone, "the file is still there")
    expect(seen.open, "the list closed")
  end)

  -- The reader rewrites the title and the note of a step with <leader>jn, in a
  -- window of its own: :w writes them to the step's line of the file, marked
  -- as edited, and leaves the other lines as they were; q leaves without a
  -- word written.
  check("trace: the title and note of a step are edited in a window", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/m.c", { "int main(void)", "{", "    return f();", "}" })
    local path = folder .. "/e.jsonl"
    write(
      path,
      lines_of({
        { title = "Editing", root = code },
        { file = "m.c", line = 1, title = "Starts" },
        { id = "s", file = "m.c", line = 3, title = "Calls f", note = "f decides" },
      })
    )
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/m.c")
      local code_win = vim.api.nvim_get_current_win()
      expect(trace.open(), "the trace was not found")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      key("<leader>jn")()
      local editor = vim.api.nvim_get_current_win()
      seen.opened = editor ~= code_win and vim.api.nvim_win_get_config(editor).relative ~= ""
      seen.shown = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      -- q with nothing changed leaves at once.
      vim.fn.maparg("q", "n", false, true).callback()
      seen.closed = not vim.api.nvim_win_is_valid(editor)
      key("<leader>jn")()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Calls f once", "", "f decides,", "", "and is never 0." })
      vim.cmd("write")
      seen.back = vim.api.nvim_get_current_win() == code_win
      seen.file = vim.fn.readfile(path)
      local namespace = vim.api.nvim_get_namespaces().config_trace
      local mark = vim.api.nvim_buf_get_extmarks(0, namespace, { 2, 0 }, { 2, 0 }, { details = true })[1]
      local card = {}
      for _, virt in ipairs(mark[4].virt_lines) do
        local parts = {}
        for _, chunk in ipairs(virt) do
          parts[#parts + 1] = chunk[1]
        end
        card[#card + 1] = vim.trim(table.concat(parts))
      end
      seen.card = card
    end)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(seen.opened, "no window opened")
    expect(vim.deep_equal(seen.shown, { "Calls f", "", "f decides" }), "the window held " .. vim.inspect(seen.shown))
    expect(seen.closed, "q did not close the window")
    expect(seen.back, ":w did not close the window")
    local step = vim.json.decode(seen.file[3])
    expect(
      #seen.file == 3
        and seen.file[2] == vim.json.encode({ file = "m.c", line = 1, title = "Starts" })
        and step.title == "Calls f once"
        and step.note == "f decides,\n\nand is never 0."
        and step.edited == true
        and step.id == "s",
      "the file: " .. vim.inspect(seen.file)
    )
    expect(
      seen.card[1]:match("^▎ 2  Calls f once ")
        and seen.card[2] == "▎  f decides,"
        and seen.card[4] == "▎  and is never 0.",
      "the card: " .. vim.inspect(seen.card)
    )
  end)
  -- A trace that answers a question about the code is copied whole with Y in
  -- the panel, as Markdown to answer from: the answer first, then every step
  -- with its place and note, a branch under its step, and what was not
  -- checked marked as such.
  check("trace: Y copies the whole trace as Markdown, the answer first", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/src/conf.c", { "int retries(void)", "{", "    return env ? atoi(env) : 3;", "}" })
    write(
      folder .. "/q.jsonl",
      lines_of({
        { title = "How many times is a request retried?", root = code },
        {
          id = "a",
          file = "src/conf.c",
          line = 3,
          title = "Three, unless set",
          note = "3 times by default.\nThe environment can change it.",
          kind = "answer",
        },
        {
          id = "e",
          parent = "a",
          file = "src/conf.c",
          line = 3,
          title = "Read from the environment",
          kind = "suspect",
        },
        { id = "f", file = "src/conf.c", line = 1, title = "The function", note = "Called once." },
      })
    )
    local seen
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/src/conf.c")
      expect(trace.open(), "the trace was not found")
      key("<leader>ja")()
      vim.wait(1000, function()
        return #require("taka.trace.panel").lines() == 3
      end, 20)
      local picker = Snacks.picker.get({ source = "trace" })[1]
      vim.fn.setreg('"', "")
      picker:action("trace_report")
      seen = vim.fn.getreg('"')
    end)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    local wanted = table.concat({
      "# How many times is a request retried?",
      "",
      "## Answer",
      "",
      "3 times by default.",
      "The environment can change it.",
      "(step 1, `src/conf.c:3`)",
      "",
      "## Steps",
      "",
      "1. **Three, unless set** `src/conf.c:3` [answer]",
      "   3 times by default.",
      "   The environment can change it.",
      "   2. **Read from the environment** `src/conf.c:3` [suspect]",
      "3. **The function** `src/conf.c:1`",
      "   Called once.",
      "",
    }, "\n")
    expect(seen == wanted, "copied:\n" .. tostring(seen))
  end)

  -- Lines added above a step move its card with them at once, and the line
  -- number the panel shows follows once the edit is made, not while typing.
  check("trace: an edit of the file moves the line numbers in the panel", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/e.c", { "int main(void)", "{", "    return run_all();", "}" })
    write(
      folder .. "/e.jsonl",
      lines_of({
        { title = "Edit", root = code },
        { file = "e.c", line = 3, text = "return run_all();", title = "Runs" },
      })
    )
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/e.c")
      local buf = vim.api.nvim_get_current_buf()
      local code_win = vim.api.nvim_get_current_win()
      key("<leader>ja")()
      vim.wait(1000, function()
        return #require("taka.trace.panel").lines() == 1
      end, 20)
      seen.before = require("taka.trace.panel").lines()[1]
      vim.api.nvim_set_current_win(code_win)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "/* one */", "/* two */" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(2000, function()
        return (require("taka.trace.panel").lines()[1] or ""):find(":5$") ~= nil
      end, 20)
      seen.after = require("taka.trace.panel").lines()[1]
    end)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(seen.before == " 1 Runs  @e.c:3", "before: " .. tostring(seen.before))
    expect(seen.after == " 1 Runs  @e.c:5", "after the edit: " .. tostring(seen.after))
  end)

  -- K in the panel shows the step's note in a small window, read without the
  -- notes in the code, which <leader>uR may have put away.
  check("trace: K in the panel shows the note of the step", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/k.c", { "int main(void)", "{", "    return 0;", "}" })
    write(
      folder .. "/k.jsonl",
      lines_of({
        { title = "Hover", root = code },
        { file = "k.c", line = 3, title = "Returns", note = "Always zero.", kind = "suspect" },
      })
    )
    local seen
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/k.c")
      key("<leader>ja")()
      vim.wait(1000, function()
        return #require("taka.trace.panel").lines() == 1
      end, 20)
      trace.show_notes(false)
      local picker = Snacks.picker.get({ source = "trace" })[1]
      vim.api.nvim_set_current_win(picker.list.win.win)
      picker:action("trace_hover")
      for _, win in ipairs(T.floats()) do
        local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "|")
        if text:find("Always zero.", 1, true) then
          seen = text
        end
      end
    end)
    trace.show_notes(true)
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(
      seen and seen:find("1. Returns", 1, true) and seen:find("[suspect]", 1, true) and seen:find("k.c:3", 1, true),
      "the window held: " .. tostring(seen)
    )
  end)

  -- Whoever writes a trace checks it the way it is read here, before handing
  -- it on: lines that could not be read, and steps whose file or line is
  -- wrong. A last line not yet ended is being written and is no problem.
  -- Read for the panel, a trace with lines left out says so once.
  check("trace: a trace is checked as it is read, and lines left out are told", function()
    local trace = require("taka.trace")
    local folder = trace_folder()
    local code = temp_dir()
    write(code .. "/c.c", { "int a;", "int b;", "int c;" })
    local path = folder .. "/c.jsonl"
    local lines = lines_of({
      { title = "Check", root = code },
      { id = "a", file = "c.c", line = 2, text = "int b;", title = "Right" },
      '{"id": "b", "file": "c.c", "line": 1, "title": "unended}',
      { id = "c", file = "c.c", line = 1, text = "int c;", title = "Off by two" },
      { id = "d", file = "gone.c", line = 1, text = "int a;", title = "No file" },
      { id = "a", file = "c.c", line = 1, text = "int a;", title = "Same id" },
      { id = "e", parent = "zz", file = "c.c", line = 1, text = "int a;", title = "No parent" },
      { id = "f", file = "c.c", line = 3, title = "No text" },
    })
    -- Being written: no line break after it yet.
    local file = assert(io.open(path, "w"))
    file:write(table.concat(lines, "\n") .. '\n{"id": "g", "file": "c.c", "li')
    file:close()
    local notices = {}
    local notify = vim.notify
    local report, count
    local ok, err = pcall(function()
      report, count = trace.check(path)
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
      trace.open(path, false)
      trace.reload()
    end)
    vim.notify = notify
    trace.close()
    store.dir = real_dir
    reset_editor()
    expect(ok, err)
    expect(vim.deep_equal(report, {
      "c.jsonl: 6 steps, 6 problems",
      "line 3: not JSON",
      "line 4, step 2 (c.c:1): the text is on line 3, not on line 1",
      "line 5, step 3 (gone.c:1): the file is not there",
      'line 6: the id "a" is given to an earlier step too',
      'line 7: the parent "zz" is not a step',
      "line 8, step 6 (c.c:3): no text, so the step cannot be found again once the code moves",
    }) and count == 6, "report: " .. vim.inspect(report))
    expect(#notices == 1 and notices[1]:find("3 lines could not be read", 1, true), "notices: " .. vim.inspect(notices))
  end)
end

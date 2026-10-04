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
      vim.deep_equal(seen.parse, { "3 [2] ▎ 2 Returns -1 | ▎   on every input" }),
      "parse.c: " .. vim.inspect(seen.parse)
    )
    expect(
      vim.deep_equal(seen.added, { "1 [3] ▎ 3 Declared here …", "3 [2] ▎ 2 Returns -1 | ▎   on every input" }),
      "added: " .. vim.inspect(seen.added)
    )
    expect(
      vim.deep_equal(
        seen.all,
        { "1 [3] ▎ 3 Declared here | ▎   a prototype", "3 [2] ▎ 2 Returns -1 | ▎   on every input" }
      ),
      "every note: " .. vim.inspect(seen.all)
    )
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
      })
    )
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(code .. "/a.c")
      local code_win = vim.api.nvim_get_current_win()
      key("<leader>ja")()
      vim.wait(1000, function()
        return #require("taka.trace.panel").lines() == 2
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
      seen.rows and seen.rows[1] == " 1 In a  @a.c:2" and seen.rows[2]:match("^└╴ 2 .+Then b  @b%.c:2$"),
      "rows: " .. vim.inspect(seen.rows)
    )
    expect(seen.shown == "b.c:2", "the code window shows " .. tostring(seen.shown))
    expect(seen.stayed, "the cursor left the panel")
  end)
end

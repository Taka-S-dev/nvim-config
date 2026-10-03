-- The call tree (lua/taka/call_tree/).
return function(T)
  local check, expect, temp_dir, write, need, run, key, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.need, T.run, T.key, T.reset_editor

  -- The call tree, both ways, on a project made to hold what broke it on real
  -- code: a prototype that is no call, a call made in a macro's body, a
  -- function that calls itself, a folder with a space in its name, a type on a
  -- line of its own before the name, a function #ifdef leaves the grammar
  -- unable to read, and more names to look up at once than global takes in
  -- one pattern.
  check("call tree: callers and callees from GTAGS, opened a branch at a time", function()
    need("gtags", "global")
    local tree = require("taka.call_tree")
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "static int leaf(int x) { return x + 1; }",
      "int mid(int x) { return leaf(x) * 2; }",
      'int top(void) { return mid(1) + mid(2) + leaf(3) + printf("") + split_type(); }',
      "int rec(int n) { return n ? rec(n - 1) : 0; }",
      "int",
      "split_type(void)",
      "{",
      "    return leaf(4);",
      "}",
    })
    write(dir .. "/sub dir/b.c", {
      "int mid(int x);",
      "int other(void) { return mid(5); }",
      "#define CALL_MID(x) mid(x)",
      "int via_macro(void) { return CALL_MID(1); }",
    })
    -- A file of its own: what comes before a part the grammar cannot read
    -- changes how it reads it.
    write(dir .. "/sub dir/d.c", {
      "int mid(int x);",
      "int broken(int n)",
      "{",
      "#ifdef A",
      "    if (n) {",
      "#else",
      "    if (!n) {",
      "#endif",
      "        return mid(6);",
      "    }",
      -- Taken for a function of its own in the part the grammar could not read.
      "    for_each_item(n) {",
      "        n = mid(7);",
      "    }",
      "    return 0;",
      "}",
      -- And this, after it, lies in that part too.
      "int after(void) { return mid(8); }",
    })
    local many, calls = {}, {}
    for i = 1, 45 do
      local name = ("a_rather_long_function_name_%02d"):format(i)
      many[#many + 1] = ("int %s(void) { return %d; }"):format(name, i)
      calls[#calls + 1] = name .. "()"
    end
    many[#many + 1] = "int many(void) { return " .. table.concat(calls, " + ") .. "; }"
    write(dir .. "/c.c", many)
    run({ "gtags" }, dir)
    local seen = {}
    local function settled()
      vim.wait(10000, function()
        local lines = tree.lines()
        return #lines > 0 and not table.concat(lines, "\n"):find("…")
      end, 20)
      return tree.lines()
    end
    local function open_row(n)
      tree.expand(Snacks.picker.get({ source = "call_tree" })[1]:items()[n].node)
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      key("<leader>jh")()
      seen.callers = settled()
      -- top, which no one calls: opened, it says so.
      open_row(3)
      settled()
      open_row(2)
      seen.mid = settled()
      -- CALL_MID, under mid: the functions that reach mid through it.
      open_row(5)
      seen.macro = settled()
      -- Enter goes to where the row's function makes the call.
      local picker = Snacks.picker.get({ source = "call_tree" })[1]
      picker.list:view(3)
      picker:action("confirm")
      seen.jumped = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      -- L: every branch below a row, three levels down.
      local function open_all()
        local finished = false
        tree.expand_all(Snacks.picker.get({ source = "call_tree" })[1]:items()[1].node, function()
          finished = true
        end)
        vim.wait(10000, function()
          return finished
        end, 20)
        return settled()
      end
      seen.all = open_all()
      tree.close()
      -- And it stops once it has added as many rows as it may.
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      key("<leader>jh")()
      settled()
      local rows = tree.limits.rows
      tree.limits.rows = 2
      local capped_ok, capped = pcall(open_all)
      tree.limits.rows = rows
      seen.capped = capped_ok and capped[1] or tostring(capped)
      tree.close()

      vim.api.nvim_win_set_cursor(0, { 3, 5 })
      key("<leader>jH")()
      seen.callees = settled()
      tree.close()
      -- On a word that is not a function, the function the cursor is in.
      vim.api.nvim_win_set_cursor(0, { 4, 30 })
      key("<leader>jH")()
      seen.recursive = settled()
      tree.close()
      key("<leader>jh")()
      seen.recursive_up = settled()
      tree.close()
      vim.cmd.edit(dir .. "/c.c")
      vim.api.nvim_win_set_cursor(0, { 46, 5 })
      key("<leader>jH")()
      seen.many = settled()
      tree.close()
    end)
    reset_editor()
    expect(ok, tostring(err))
    local function same(got, want, what)
      expect(table.concat(got, "\n") == table.concat(want, "\n"), what .. ":\n" .. table.concat(got, "\n"))
    end
    same(seen.callers, {
      "▾ leaf  @a.c:1",
      "├╴▸ mid  @a.c:2",
      "├╴▸ top  @a.c:3",
      "└╴▸ split_type  @a.c:8",
    }, "callers of leaf")
    same(seen.mid, {
      "▾ leaf  @a.c:1",
      "├╴▾ mid  @a.c:2",
      "│ ├╴▸ top  @a.c:3",
      "│ ├╴▸ other  @b.c:2",
      "│ ├╴▸ CALL_MID  macro  @b.c:3",
      "│ ├╴▸ broken  ×2  @d.c:9",
      "│ └╴▸ after  @d.c:16",
      "├╴  top  no callers  @a.c:3",
      "└╴▸ split_type  @a.c:8",
    }, "callers of mid, opened under leaf")
    expect(
      vim.tbl_contains(seen.macro, "│ │ └╴▸ via_macro  @b.c:4"),
      "under CALL_MID:\n" .. table.concat(seen.macro, "\n")
    )
    expect(seen.jumped == "a.c:3", "Enter on top went to " .. tostring(seen.jumped))
    same(seen.all, {
      "▾ leaf  @a.c:1",
      "├╴▾ mid  @a.c:2",
      "│ ├╴  top  no callers  @a.c:3",
      "│ ├╴  other  no callers  @b.c:2",
      "│ ├╴▾ CALL_MID  macro  @b.c:3",
      -- The third level below, shown but not opened.
      "│ │ └╴▸ via_macro  @b.c:4",
      "│ ├╴  broken  ×2  no callers  @d.c:9",
      "│ └╴  after  no callers  @d.c:16",
      "├╴  top  no callers  @a.c:3",
      "└╴▾ split_type  @a.c:8",
      "  └╴  top  no callers  @a.c:3",
    }, "L on leaf")
    expect(seen.capped == "▾ leaf  opened until 2 rows  @a.c:1", "L stopped at 2 rows: " .. tostring(seen.capped))
    -- A click opens a branch on its ▸ only, not on the guide before it (whose
    -- first byte ▸ shares) or on the name. Columns are bytes, as getmousepos()
    -- gives them: " ├╴▸ mid" has ▸ at 8.
    local clicks = {}
    for _, column in ipairs({ 2, 5, 8, 10, 12 }) do
      clicks[#clicks + 1] = tostring(tree.on_mark(" ├╴▸ mid", column))
    end
    expect(table.concat(clicks, " ") == "false false true true false", "on the mark: " .. table.concat(clicks, " "))
    same(seen.callees, {
      "▾ top  @a.c:3",
      "├╴▸ mid  @a.c:3",
      "├╴▸ leaf  @a.c:3",
      "├╴  printf  not in GTAGS  @a.c:3",
      -- Defined with its type on the line above its name.
      "└╴▸ split_type  @a.c:3",
    }, "callees of top")
    same(seen.recursive, { "▾ rec  @a.c:4", "└╴  rec  ↻  @a.c:4" }, "callees of rec")
    same(seen.recursive_up, { "▾ rec  @a.c:4", "└╴  rec  ↻  @a.c:4" }, "callers of rec")
    local unknown = vim.tbl_filter(function(line)
      return line:find("not in GTAGS")
    end, seen.many)
    expect(#seen.many == 46 and #unknown == 0, ("callees of many: %d rows, %d not found"):format(#seen.many, #unknown))
  end)
  -- The panel knows a source only by the interface at the top of
  -- lua/taka/call_tree/init.lua. One that answers from a graph in memory, after
  -- a turn of the event loop as a language server would, is drawn and opened as
  -- GTAGS is; a source that cannot answer for the buffer passes to the next,
  -- and when none can, the first one's reason is shown.
  check("call tree: a source that keeps to the interface is drawn as GTAGS is", function()
    local tree = require("taka.call_tree")
    -- parse calls itself through expr: only the rows above tell it.
    local graph =
      { main = { "parse", "print", "missing" }, parse = { "next_token", "expr" }, expr = { "parse" }, print = {} }
    local asked = {}
    local function node(name, line)
      return {
        name = name,
        kind = graph[name] and "function" or "unknown",
        file = "/src/" .. name .. ".x",
        lnum = 1,
        sites = { { file = "/src/main.x", lnum = line } },
      }
    end
    package.loaded["call_tree_test.none"] = {
      attach = function()
        return nil, "no server for this buffer"
      end,
    }
    package.loaded["call_tree_test.graph"] = {
      attach = function()
        return {
          unknown = "not on the server",
          start = function(_, _, done)
            done({ name = "main", kind = "function", file = "/src/main.x", lnum = 1 })
          end,
          children = function(_, parent, direction, done)
            asked[#asked + 1] = direction .. ":" .. parent.name
            vim.schedule(function()
              local out = {}
              for line, name in ipairs(graph[parent.name] or {}) do
                out[#out + 1] = node(name, line + 1)
              end
              done(out)
            end)
          end,
          branches = function(_, parent)
            return parent.kind == "function"
          end,
        }
      end,
    }
    local sources = tree.sources
    local notify = vim.notify
    local seen = {}
    local ok, err = pcall(function()
      local function settled()
        vim.wait(3000, function()
          local lines = tree.lines()
          return #lines > 0 and not table.concat(lines, "\n"):find("…")
        end, 20)
        return tree.lines()
      end
      tree.sources = { "call_tree_test.none", "call_tree_test.graph" }
      tree.start("callers")
      settled()
      tree.expand(Snacks.picker.get({ source = "call_tree" })[1]:items()[2].node)
      settled()
      tree.expand(Snacks.picker.get({ source = "call_tree" })[1]:items()[4].node)
      seen.tree = settled()
      Snacks.picker.get({ source = "call_tree" })[1]:action("call_turn")
      settled()
      seen.title = Snacks.picker.get({ source = "call_tree" })[1].title
      tree.close()
      vim.notify = function(message)
        seen.message = message
      end
      tree.sources = { "call_tree_test.none" }
      tree.start("callers")
    end)
    tree.sources, vim.notify = sources, notify
    package.loaded["call_tree_test.none"], package.loaded["call_tree_test.graph"] = nil, nil
    reset_editor()
    expect(ok, tostring(err))
    local function same(got, want, what)
      expect(table.concat(got, "\n") == table.concat(want, "\n"), what .. ":\n" .. table.concat(got, "\n"))
    end
    same(seen.tree, {
      "▾ main  @main.x:1",
      "├╴▾ parse  @main.x:2",
      "│ ├╴  next_token  not on the server  @main.x:2",
      "│ └╴▾ expr  @main.x:3",
      "│   └╴  parse  ↻  @main.x:2",
      "├╴▸ print  @main.x:3",
      "└╴  missing  not on the server  @main.x:4",
    }, "the tree from a graph in memory")
    expect(seen.title == "Callees of main", "turned round: " .. tostring(seen.title))
    expect(
      table.concat(asked, " ") == "callers:main callers:parse callers:expr callees:main",
      "asked the source: " .. table.concat(asked, " ")
    )
    expect(seen.message == "no server for this buffer", "with no source to answer: " .. tostring(seen.message))
  end)
end

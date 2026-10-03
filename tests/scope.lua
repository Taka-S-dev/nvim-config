-- The scope line and its pin (lua/taka/scope_pin.lua).
return function(T)
  local check, expect, temp_dir, write, key, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.key, T.reset_editor

  -- An if without braces whose body is another if: the inner one is a field
  -- of the outer in treesitter's view, and snacks passed it over for the
  -- outer, so the scope line lit up the wrong block.
  check("scope: a nested if under a brace-less if gets its own scope line", function()
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "int f(int a, int b)",
      "{",
      "    if (a)",
      "        if (b) {",
      "            return 1;",
      "        }",
      "    return 0;",
      "}",
    })
    vim.cmd.edit(dir .. "/a.c")
    vim.treesitter.get_parser(0):parse(true)
    local got = {}
    for _, line in ipairs({ 4, 5 }) do
      Snacks.scope.get(function(scope)
        got[#got + 1] = ("%d:%s-%s@%s"):format(
          line,
          scope and scope.from or "?",
          scope and scope.to or "?",
          scope and scope.indent or "?"
        )
      end, { buf = 0, pos = { line, 8 } })
      vim.wait(1000, function()
        return #got == #got
      end, 50)
    end
    vim.wait(500)
    reset_editor()
    expect(table.concat(got, " ") == "4:4-6@8 5:4-6@8", "scopes: " .. table.concat(got, " "))
  end)
  check("scope pin: the line stays on its block while the cursor leaves", function()
    require("taka.scope_pin")
    local dir = temp_dir()
    local lines = { "int f(void)", "{", "    while (1) {", "        a();", "        b();", "    }" }
    for i = 1, 100 do
      lines[#lines + 1] = "    c();"
    end
    lines[#lines + 1] = "}"
    write(dir .. "/a.c", lines)
    vim.cmd.edit(dir .. "/a.c")
    vim.treesitter.get_parser(0):parse(true)
    vim.fn.cursor(4, 9)
    key("<leader>jl")()
    vim.wait(1500, function()
      return vim.b.scope_pin ~= nil
    end, 50)
    local pinned = vim.b.scope_pin
    vim.fn.cursor(90, 1)
    vim.cmd("normal! zt")
    local ns = vim.api.nvim_get_namespaces().config_scope_pin
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    local rows = {}
    for _, mark in ipairs(marks) do
      rows[#rows + 1] = mark[2] + 1
    end
    key("<leader>jl")()
    local after = #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    reset_editor()
    expect(pinned and pinned.from == 3 and pinned.to == 6, "pinned block: " .. vim.inspect(pinned))
    expect(table.concat(rows, ",") == "4,5", "lines drawn after moving away: " .. table.concat(rows, ","))
    expect(after == 0, "pressing the key again did not take the line away")
  end)
end

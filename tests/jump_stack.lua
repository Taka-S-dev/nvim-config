-- The jump stack (lua/taka/jump_stack.lua).
return function(T)
  local check, expect, temp_dir, write, run, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.run, T.reset_editor

  -- The jump stack is Vim's tag stack, onto which every kind of jump goes, so
  -- it is the same for any language: here a jump in C, then one in Lua, each
  -- level named by the function it was made from. A headless run moves no
  -- cursor through the screen, so what CursorMoved would call is called here.
  check("jump stack: the jumps the cursor is inside, in C and Lua alike", function()
    local stack = require("taka.jump_stack")
    local pins = require("taka.pins")
    local dir = temp_dir()
    write(
      dir .. "/a.c",
      { "int helper(int x)", "{", "    return x + 1;", "}", "int main(void)", "{", "    return helper(2);", "}" }
    )
    write(dir .. "/b.lua", {
      "local function greet(name)",
      '  return "hi " .. name',
      "end",
      "local function run()",
      -- A line that starts with a call: the call is no function of its own.
      '  greet("x")',
      "end",
    })
    -- A function an #ifdef hides from the grammar, named all the same.
    write(dir .. "/c.c", {
      "int broken(int n)",
      "{",
      "#ifdef A",
      "    if (n) {",
      "#else",
      "    if (!n) {",
      "#endif",
      "        return helper(6);",
      "    }",
      "    for_each_item(n) {",
      "        n = 7;",
      "    }",
      "    return 0;",
      "}",
    })
    local function jump(tag, file, line)
      local from = vim.fn.getpos(".")
      from[1] = vim.api.nvim_get_current_buf()
      vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = { { tagname = tag, from = from } } }, "t")
      vim.cmd.edit(file)
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      stack.track()
      vim.wait(50)
    end
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/c.c")
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 8, 15 })
      jump("helper", dir .. "/a.c", 3)
      vim.cmd.edit(dir .. "/b.lua")
      vim.api.nvim_win_set_cursor(0, { 5, 9 })
      stack.track()
      jump("greet", dir .. "/b.lua", 2)
      stack.toggle()
      vim.wait(300)
      seen.two = stack.lines()
      -- A level shown from the panel within the second after the jump, as a
      -- double click can be: the cursor moved there is not taken for the jump
      -- settling, and the landing stays.
      stack.visit(stack.rows(win)[1])
      stack.track(win)
      seen.landing_kept = stack.lines()[3]
      -- Back a level from the panel, as <C-t> in the code: the level stays,
      -- and the mark goes up one.
      stack.back_to(stack.rows(win)[2])
      vim.wait(300)
      seen.popped = stack.lines()
      -- Showing a level moves the window there and leaves the stack alone.
      local rows = stack.rows(win)
      stack.visit(rows[1])
      seen.visited = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), ":t")
        .. ":"
        .. vim.api.nvim_win_get_cursor(win)[1]
        .. " at level "
        .. vim.fn.gettagstack(win).curidx
      -- Pinned, the levels nest.
      local added, root = pins.add_chain({})
      seen.nothing = added
      stack.pin()
      root = vim.fs.normalize(dir)
      seen.pinned = pins.outline(root)
      os.remove(pins.store_path(root))
      -- Going back to a level is :pop down to it.
      stack.back_to(stack.rows(win)[1])
      seen.back = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".") .. " at level " .. vim.fn.gettagstack(win).curidx
      stack.clear()
      vim.wait(300)
      seen.cleared = #stack.lines()
      stack.toggle()
    end)
    reset_editor()
    expect(ok, tostring(err))
    local function same(got, want, what)
      expect(table.concat(got, "\n") == table.concat(want, "\n"), what .. ":\n" .. table.concat(got, "\n"))
    end
    same(seen.two, {
      "  broken  → helper  @c.c:8",
      "  run  → greet  @b.lua:5",
      " greet  @b.lua:2",
    }, "after a jump in C and one in Lua")
    same(seen.popped, {
      "  broken  → helper  @c.c:8",
      " run  → greet  @b.lua:5",
      "  greet  @b.lua:2",
    }, "back a level")
    expect(seen.visited == "c.c:8 at level 2", "showing the first level: " .. tostring(seen.visited))
    expect(
      tostring(seen.landing_kept):find("greet  @b.lua:2", 1, true),
      "the landing after a click in the panel: " .. tostring(seen.landing_kept)
    )
    -- The window the panel follows can be closed; its stack is then empty.
    local gone = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "below" })
    vim.api.nvim_win_close(gone, true)
    local rows_ok, rows = pcall(stack.rows, gone)
    expect(rows_ok and #rows == 0, "the rows of a closed window: " .. tostring(rows))
    expect(seen.nothing == 0, "an empty chain pinned " .. tostring(seen.nothing))
    same(seen.pinned or {}, { "0:broken → helper", "1:run → greet", "2:greet" }, "the levels pinned")
    expect(seen.back == "c.c:8 at level 1", "back to the first level: " .. tostring(seen.back))
    expect(seen.cleared == 0, "rows left after emptying the stack: " .. tostring(seen.cleared))
  end)

  -- Back in a level by <C-o> or a click rather than <C-t>, Vim still stacks the
  -- next jump on top, and the same function showed up level after level. The
  -- stack goes back to that level instead; a jump from where the last one
  -- landed, into the same function as a recursive call is, still goes deeper.
  check("jump stack: back in a level without <C-t>, the next jump replaces the levels below", function()
    local stack = require("taka.jump_stack")
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "int helper(int x)",
      "{",
      "    return x ? helper(x - 1) : 0;",
      "}",
      "int main(void)",
      "{",
      "    return helper(2);",
      "}",
    })
    -- The cursor reaches where the jump went by way of a line next to the
    -- start, as smooth scrolling carries it: the landing is where it stops.
    local function jump(line_from, col_from, line_to)
      vim.api.nvim_win_set_cursor(0, { line_from, col_from })
      local from = vim.fn.getpos(".")
      from[1] = vim.api.nvim_get_current_buf()
      vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = { { tagname = "helper", from = from } } }, "t")
      vim.api.nvim_win_set_cursor(0, { line_from - 1, 0 })
      stack.track()
      vim.wait(50)
      vim.api.nvim_win_set_cursor(0, { line_to, 0 })
      stack.track()
    end
    local function names()
      return table.concat(
        vim.tbl_map(function(row)
          return row.name .. ":" .. row.lnum
        end, stack.rows(vim.api.nvim_get_current_win())),
        " "
      )
    end
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = {} }, "r")
      jump(7, 11, 3)
      -- Back to main with something other than <C-t>, and the same jump again.
      jump(7, 11, 3)
      seen.again = names()
      -- From where it landed into helper again, twice, as a recursive call
      -- goes: a level deeper each time, though helper is on the stack.
      jump(3, 15, 1)
      jump(3, 15, 1)
      seen.deeper = names()
    end)
    vim.cmd("bwipeout!")
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.again == "main:7 helper:3", "the same jump twice: " .. tostring(seen.again))
    expect(seen.deeper == "main:7 helper:3 helper:3 helper:1", "a recursive jump: " .. tostring(seen.deeper))
  end)
end

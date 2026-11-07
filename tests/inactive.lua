-- The blocks of C that #if leaves out, grey, for macros set by hand
-- (lua/taka/inactive.lua).
return function(T)
  local check, expect, temp_dir, reset_editor = T.check, T.expect, T.temp_dir, T.reset_editor

  -- The rows grey for a source and the macros set, as their line numbers.
  local function grey(lines, defines)
    local inactive = require("taka.inactive")
    local kept = inactive.text()
    assert(inactive.set(defines))
    local rows = inactive.rows(lines)
    inactive.set(kept)
    local out = {}
    for row in pairs(rows) do
      out[#out + 1] = row + 1
    end
    table.sort(out)
    return table.concat(out, " ")
  end

  -- The branches a build with the macros set leaves out, and no others: a
  -- condition naming a macro not set is left plain, and so is every branch
  -- after it, as which one is taken is not known.
  check("inactive: the branches #if leaves out for the macros set, and only those", function()
    local source = {
      "#ifdef A", -- 1
      "a();", -- 2
      "#else", -- 3
      "not_a();", -- 4
      "#endif", -- 5
      "#if defined(B) && VERSION >= 3", -- 6
      "b3();", -- 7
      "#elif UNSET", -- 8
      "unset();", -- 9
      "#else", -- 10
      "other();", -- 11
      "#endif", -- 12
      "#if 0", -- 13
      "zero();", -- 14
      "#endif", -- 15
      "#ifndef C", -- 16
      "#  if A", -- 17
      "nested();", -- 18
      "#  endif", -- 19
      "#endif", -- 20
      "#if X \\", -- 21
      "    || A", -- 22
      "x_or_a();", -- 23
      "#endif", -- 24
    }
    local cases = {
      -- A set: its #else is out. B unset with VERSION 2: false, then UNSET is
      -- not known, so neither it nor #else is greyed. C not defined: in.
      { "A !B VERSION=2 !C", "4 7 14" },
      -- C defined, so the #ifndef C block is out, `#if A` and its lines with it;
      -- `X || A` names X, not set, so it is left plain though A is out.
      { "!A B VERSION=3 C", "2 9 11 14 17 18 19" },
      -- Nothing set: only #if 0.
      { "", "14" },
    }
    for _, case in ipairs(cases) do
      local got = grey(source, case[1])
      expect(got == case[2], ("%q greyed %s, not %s"):format(case[1], got, case[2]))
    end
    -- A number's suffix or hex digits are not names: `10UL` and `0x1F` alone
    -- are worked out.
    expect(grey({ "#if 10UL > 0x1F", "big();", "#endif" }, "") == "2", "10UL > 0x1F")
    local inactive = require("taka.inactive")
    expect(inactive.set("A B=2 !C") and inactive.text() == "A B=2 !C", "the text: " .. inactive.text())
    expect(not inactive.set("A 2B"), "2B taken as a name")
    expect(inactive.text() == "A B=2 !C", "a wrong word changed the macros: " .. inactive.text())
    inactive.set("")
  end)

  -- The list of macros: the names in the file's conditions in order, Enter
  -- going round not set, defined, not defined; a name typed that is in no
  -- row added; <C-x> leaving one not set; and the cursor kept on the row.
  check("inactive: the list of macros sets them one by one, the cursor kept", function()
    local inactive = require("taka.inactive")
    inactive.set("")
    local dir = temp_dir()
    vim.cmd.edit(dir .. "/l.c")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "#if defined(ZED) && VERSION > 2 /* OLD */",
      "#endif",
      "#ifdef ALPHA",
      "#elif !defined(ZED)",
      "#endif",
    })
    local names = vim.tbl_map(function(entry)
      return entry.name .. entry.uses
    end, inactive.names(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
    expect(table.concat(names, " ") == "ZED2 VERSION1 ALPHA1", "the names: " .. table.concat(names, " "))
    inactive.ask()
    local picker = Snacks.picker.get({ source = "inactive_macros" })[1]
    expect(picker ~= nil, "the list did not open")
    if not picker then
      return
    end
    local function settle()
      vim.wait(200)
      vim.wait(3000, function()
        return not picker:is_active()
      end, 20)
    end
    settle()
    picker.list:view(2)
    local states = {}
    for _ = 1, 3 do
      picker:action("confirm")
      settle()
      states[#states + 1] = tostring(inactive.defines.VERSION) .. "@" .. picker.list.cursor
    end
    vim.api.nvim_buf_set_lines(picker.input.win.buf, 0, -1, false, { "NEW_ONE" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = picker.input.win.buf })
    settle()
    picker:action("confirm")
    settle()
    local added = inactive.defines.NEW_ONE
    local listed = #picker:items()
    picker.list:view(1)
    picker:action("confirm")
    picker:action("macro_unset")
    local unset = inactive.defines.ZED
    -- <C-a> then <C-x>: every macro back to not set, those of no row here too.
    inactive.put("ELSEWHERE", false)
    picker:find()
    settle()
    picker:action("select_all")
    picker:action("macro_unset")
    local left = inactive.text()
    picker:close()
    inactive.set("")
    reset_editor()
    expect(table.concat(states, " ") == "1@2 false@2 nil@2", "Enter on VERSION: " .. table.concat(states, " "))
    expect(added == "1" and listed == 4, ("a name typed: %s, %d rows"):format(tostring(added), listed))
    expect(unset == nil, "<C-x> left ZED " .. tostring(unset))
    expect(left == "", "<C-a> <C-x> left " .. left)
  end)

  -- In a C buffer the grey is drawn on the lines left out, the text only.
  check("inactive: the lines left out are drawn grey in a C buffer", function()
    local inactive = require("taka.inactive")
    local dir = temp_dir()
    vim.cmd.edit(dir .. "/i.c")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#ifdef A", "a();", "#else", "b();", "#endif" })
    vim.bo.filetype = "c"
    inactive.set("A")
    local ns = vim.api.nvim_get_namespaces()["taka.inactive"]
    expect(ns ~= nil, "no namespace")
    expect(vim.api.nvim_get_hl(0, { name = "PreprocInactive" }).fg ~= nil, "no colour for the lines left out")
    inactive.set("")
    reset_editor()
  end)
end

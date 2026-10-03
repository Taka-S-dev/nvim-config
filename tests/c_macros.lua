-- Macros and enum values told apart in C (lua/taka/c_macros.lua).
return function(T)
  local check, expect, temp_dir, write, need, run, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.need, T.run, T.reset_editor

  -- Which capitalised name is a macro and which an enum value, from the file's
  -- own definitions and from the tags file; a lowercase name only from the
  -- file, and a name found nowhere left to the grammar.
  check("c macros: macros and enum values are told apart where they are used", function()
    local names = require("taka.c_macros")
    local dir = temp_dir()
    write(dir .. "/tags", {
      "!_TAG_FILE_FORMAT\t2\t/extended format/",
      "!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/",
      'TAGGED_ENUM\tb.h\t/^    TAGGED_ENUM,$/;"\te\tenum:state',
      'TAGGED_MACRO\tb.h\t/^#define TAGGED_MACRO 1$/;"\td',
      -- The macro before the enum value, so the value must not undo it.
      'Tagged_both\tb.h\t/^#define Tagged_both Tagged_both$/;"\td',
      'Tagged_both\tb.h\t/^    Tagged_both,$/;"\te\tenum:state',
      'tagged_lower\tb.h\t/^#define tagged_lower 2$/;"\td',
    })
    write(dir .. "/a.c", {
      "#define LOCAL_MAX 10",
      "#define twice(x) ((x) * 2)",
      "enum colour { red, GREEN };",
      "int f(int n)",
      "{",
      "    return twice(n) + LOCAL_MAX + red + GREEN + TAGGED_MACRO + TAGGED_ENUM + Tagged_both",
      "        + tagged_lower + UNKNOWN_NAME + f(n);",
      "}",
    })
    vim.cmd.edit(dir .. "/a.c")
    vim.treesitter.get_parser(0):parse(true)
    local function seen()
      local out = {}
      local rows = names.marks(0, 0, 7) or {}
      for _, row in ipairs({ 5, 6 }) do
        for _, mark in ipairs(rows[row] or {}) do
          local text = vim.api.nvim_buf_get_text(0, row, mark[1], row, mark[2], {})[1]
          out[#out + 1] = text .. "=" .. mark[3]:sub(2)
        end
      end
      return table.concat(out, " ")
    end
    local want = "twice=Macro LOCAL_MAX=Macro red=Enum GREEN=Enum TAGGED_MACRO=Macro TAGGED_ENUM=Enum Tagged_both=Macro"
    local got = seen()
    vim.wait(2000, function()
      got = seen()
      return got == want
    end, 20)
    -- A macro defined while editing counts once the typing stops, not at
    -- every key.
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "#define ADDED 1", "int h(void) { return ADDED; }" })
    vim.treesitter.get_parser(0):parse(true)
    local function added()
      local rows = names.marks(0, 9, 9) or {}
      return rows[9] and #rows[9] or 0
    end
    local at_once = added()
    vim.wait(2000, function()
      return added() == 1
    end, 20)
    local settled = added()
    reset_editor()
    expect(got == want, "marked: " .. got)
    expect(at_once == 0 and settled == 1, ("a macro added: at once %d, after a pause %d"):format(at_once, settled))
    -- Headers too, where most macros are: they open as C, which has a parser.
    local header = vim.filetype.match({ filename = dir .. "/b.h" })
    expect(header == "c", "a header opens as " .. tostring(header))
  end)
  -- A project indexed by gtags alone, with no tags file: a macro in a header
  -- is known from the #define global finds it on, and an enum value, which
  -- its line does not tell, is left to the grammar. Until the way to start
  -- global is known, global -p goes first, so that an answer that is rightly
  -- empty does not drop the way remembered.
  check("c macros: a header's macros from gtags, when there is no tags file", function()
    need("gtags", "global")
    local names = require("taka.c_macros")
    local global = require("taka.lib.gtags_global")
    local dir = temp_dir()
    write(dir .. "/b.h", {
      "#define H_MAX 3",
      "#define Twice_It(x) ((x) * 2)",
      "enum colour { RED_ONE, GREEN_ONE };",
    })
    -- More names on one line than global takes in one pattern of 512 bytes.
    local long, uses = {}, {}
    for i = 1, 30 do
      long[#long + 1] = ("#define A_RATHER_LONG_MACRO_NAME_%02d %d"):format(i, i)
      uses[#uses + 1] = ("A_RATHER_LONG_MACRO_NAME_%02d"):format(i)
    end
    write(dir .. "/c.h", long)
    write(dir .. "/a.c", {
      '#include "b.h"',
      "int f(void) { return Twice_It(H_MAX) + RED_ONE + Not_Here; }",
      "int g(void) { return " .. table.concat(uses, " + ") .. "; }",
    })
    run({ "gtags" }, dir)
    local calls = {}
    local real_run, real_confirmed = global.run, global.confirmed
    global.confirmed = function()
      return false
    end
    global.run = function(root, args, done)
      calls[#calls + 1] = args[1]
      return real_run(root, args, done)
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      vim.treesitter.get_parser(0):parse(true)
      local function seen()
        local out = {}
        for _, mark in ipairs((names.marks(0, 1, 1) or {})[1] or {}) do
          out[#out + 1] = vim.api.nvim_buf_get_text(0, 1, mark[1], 1, mark[2], {})[1] .. "=" .. mark[3]:sub(2)
        end
        return table.concat(out, " ")
      end
      local got
      vim.wait(10000, function()
        got = seen()
        return got == "Twice_It=Macro H_MAX=Macro"
      end, 50)
      vim.wait(300)
      calls.got = seen()
      local function long_ones()
        local rows = names.marks(0, 2, 2) or {}
        return rows[2] and #rows[2] or 0
      end
      vim.wait(10000, function()
        return long_ones() == 30
      end, 50)
      calls.long = long_ones()
    end)
    global.run, global.confirmed = real_run, real_confirmed
    reset_editor()
    expect(ok, tostring(err))
    expect(calls.got == "Twice_It=Macro H_MAX=Macro", "marked: " .. tostring(calls.got))
    expect(calls.long == 30, ("of 30 macros with long names on one line, %d marked"):format(calls.long or 0))
    expect(calls[1] == "-p" and calls[2] == "-x", "global run with: " .. table.concat(calls, ", "))
  end)
end

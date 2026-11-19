-- Where a C name is written to (lua/taka/writes.lua).
return function(T)
  local check, expect, temp_dir, write, need, key = T.check, T.expect, T.temp_dir, T.write, T.need, T.key

  -- A heading that is renamed leaves the links to it pointing nowhere, and
  -- nothing says so until a reader follows one.
  -- The help is where the keys are told (doc/cfg.txt, :h cfg). A key added
  -- without a word there, or a |link| to a tag that was renamed, fails here,
  -- so the help does not fall behind the config.
  -- Where a name is written to: an assignment, an operator assignment, ++ and
  -- --, a declaration's value and a designated initializer, a member and a
  -- variable of the same name alike; not a comparison, a subscript that only
  -- reads the name, a comment or a string. A folder with a space in its name
  -- is looked in all the same.
  check("writes: the places a C name is written to, by the grammar", function()
    need("rg")
    local writes = require("taka.writes")
    local dir = temp_dir()
    write(dir .. "/sub dir/a.c", {
      "struct st { int count; int *arr; };",
      "int count = 0;",
      "void f(struct st *s, int *p)",
      "{",
      "    int n = count;",
      "    count = 1;",
      "    count += 2;",
      "    if (count == 3) {}",
      "    count++;",
      "    --count;",
      "    s->count = 4;",
      "    s->arr[count] = 5;",
      "    /* count = 9; */",
      '    printf("count = %d", count);',
      "    static struct st init = { .count = 7 };",
      "    *p = count;",
      "    int (*fp)(void) = 0, counter = 1;",
      "}",
    })
    local function places(name)
      local got
      writes.find(name, dir, function(items)
        got = items
      end)
      vim.wait(10000, function()
        return got ~= nil
      end, 20)
      return table.concat(
        vim.tbl_map(function(item)
          return item.lnum .. ":" .. item.col
        end, got or {}),
        " "
      )
    end
    local count, fp = places("count"), places("fp")
    expect(count == "2:5 6:5 7:5 9:5 10:7 11:8 15:32", "count written at " .. count)
    expect(fp == "17:11", "fp written at " .. fp)
  end)

  -- A Shift-JIS file is parsed as the editor reads it. As bytes, the trail
  -- byte of 表 and 予 is a backslash: it carried a // comment on to the next
  -- line and escaped the quote ending a string, and the writes there were
  -- missed. Each line is shown as the whole file reads, so a line whose
  -- bytes happen to be UTF-8 (ﾃｽ is C3 BD) is not read on its own as UTF-8.
  check("writes: a Shift-JIS file is read as the editor reads it", function()
    need("rg")
    local writes = require("taka.writes")
    local dir = temp_dir()
    local lines = {
      "// 予定表",
      "count = 1;",
      'puts("表");',
      "count = 2;",
      "/* ﾃｽ */ count = 3;",
      "count += 4;",
    }
    local handle = assert(io.open(dir .. "/s.c", "wb"))
    handle:write(vim.iconv(table.concat(lines, "\r\n") .. "\r\n", "utf-8", "cp932"))
    handle:close()
    local got
    writes.find("count", dir, function(items)
      got = items
    end)
    vim.wait(10000, function()
      return got ~= nil
    end, 20)
    local places = table.concat(
      vim.tbl_map(function(item)
        return item.lnum .. ":" .. item.col
      end, got or {}),
      " "
    )
    expect(places == "2:1 4:1 5:14 6:1", "count written at " .. places)
    local third = (got or {})[3] or {}
    expect(third.text == "/* ﾃｽ */ count = 3;", "the line shown: " .. tostring(third.text))
  end)
end

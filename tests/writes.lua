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
end

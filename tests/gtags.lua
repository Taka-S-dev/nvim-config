-- gtags and ctags: jumps, the peek, index builds, the statusline
-- (lua/taka/gtags/).
return function(T)
  local results, skip, check, expect, temp_dir, write, need, run, key, floats, press, reset_editor, c_project =
    T.results,
    T.skip,
    T.check,
    T.expect,
    T.temp_dir,
    T.write,
    T.need,
    T.run,
    T.key,
    T.floats,
    T.press,
    T.reset_editor,
    T.c_project

  check("gtags: <leader>jb builds in the background and <C-]> lands on the definition", function()
    need("gtags", "global")
    local dir = c_project()
    vim.api.nvim_set_current_dir(dir)
    vim.cmd.edit(dir .. "/main.c")
    local started = vim.uv.hrtime()
    key("<leader>jb")()
    expect((vim.uv.hrtime() - started) / 1e6 < 1000, "the build key did not return at once")
    expect(
      vim.wait(30000, function()
        return vim.uv.fs_stat(dir .. "/GTAGS") ~= nil and not tostring(vim.g.background_activity):find("Building")
      end, 50),
      "GTAGS was not built"
    )

    vim.cmd.edit(dir .. "/main.c")
    vim.fn.cursor(5, 12)
    expect(vim.fn.expand("<cword>") == "target_fn", "the cursor is not on the call")
    local from = vim.api.nvim_get_current_buf()
    key("<C-]>")()
    expect(
      vim.wait(15000, function()
        return vim.api.nvim_get_current_buf() ~= from
      end, 20),
      "the jump did not happen"
    )
    local landed = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    -- The statusline says how many it found, not only that global answered.
    local reported = tostring(vim.g.background_activity)

    -- A name global once came back empty for is asked again the next time,
    -- not remembered as having no definition until Neovim is restarted.
    local global = require("taka.lib.gtags_global")
    local real_run, asked = global.run, 0
    global.run = function(root, args, done)
      asked = asked + 1
      if asked == 1 then
        return done("")
      end
      return real_run(root, args, done)
    end
    local notify = vim.notify
    vim.notify = function() end
    local second
    local ok, err = pcall(function()
      for attempt = 1, 2 do
        vim.cmd.edit(dir .. "/main.c")
        vim.fn.cursor(3, 5)
        key("<C-]>")()
        vim.wait(5000, function()
          return asked >= attempt
        end, 20)
        vim.wait(200)
      end
      second = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    end)
    global.run, vim.notify = real_run, notify
    reset_editor()
    expect(ok, tostring(err))
    expect(landed == "lib.c:1", "landed on " .. landed)
    expect(reported:find("(global, 1 found)", 1, true), "the statusline said: " .. reported)
    expect(asked == 2 and second == "main.c:3", ("global asked %d times, the second jump on %s"):format(asked, second))
  end)
  -- A session opened over ssh will not pass through scoop's `current`
  -- junctions, the shims' included, so the tools this config runs are found in
  -- the folder of their version, down a path with no junction in it. Only where
  -- scoop put a shim for them.
  -- Where names are compared without case, as on Windows, a folder named gtags
  -- was taken for a GTAGS: the files beside it were looked up in an index that
  -- is not there. Only a file named GTAGS makes a root.
  check("gtags root: a GTAGS file makes one, a folder named gtags does not", function()
    local dir = temp_dir()
    write(dir .. "/src/a.c", { "int a;" })
    vim.fn.mkdir(dir .. "/src/gtags", "p")
    local root = require("taka.lib.gtags_global").root
    local before = root(dir .. "/src/a.c")
    write(dir .. "/GTAGS", { "" })
    local after = root(dir .. "/src/a.c")
    expect(before == nil, "a folder named gtags made a root: " .. tostring(before))
    expect(
      after and vim.fs.normalize(after) == vim.fs.normalize(dir),
      "the GTAGS above was not found: " .. tostring(after)
    )
  end)

  -- <C-]> on a name where it is defined, as on a macro in its own #define,
  -- went to the line it was on and still put a jump on the tag stack: each
  -- press added a level to the jump stack. It adds none. Nor does a name with
  -- several definitions until one is chosen from the list: closed without a
  -- choice, the list left a level that went nowhere.
  check("gtags: <C-]> puts no jump on the tag stack until it moves", function()
    need("gtags", "global")
    local dir = c_project()
    write(dir .. "/x.c", { "int twice(void)", "{", "    return 1;", "}" })
    write(dir .. "/y.c", { "int twice(void)", "{", "    return 2;", "}", "int caller(void) { return twice(); }" })
    run({ "gtags" }, dir)
    vim.cmd.edit(dir .. "/lib.c")
    vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = {} }, "r")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    local notify, said = vim.notify, nil
    vim.notify = function(message)
      said = message
    end
    local ok, err = pcall(function()
      for _ = 1, 3 do
        key("<C-]>")()
        vim.wait(3000, function()
          return said ~= nil
        end, 20)
      end
    end)
    vim.notify = notify
    local depth = #vim.fn.gettagstack().items
    -- Several definitions: a list, and nothing on the tag stack yet.
    vim.cmd.edit(dir .. "/y.c")
    vim.api.nvim_win_set_cursor(0, { 5, 27 })
    key("<C-]>")()
    vim.wait(5000, function()
      return Snacks.picker.get()[1] ~= nil
    end, 20)
    local listed = Snacks.picker.get()[1] ~= nil
    local listed_depth = #vim.fn.gettagstack().items
    for _, picker in ipairs(Snacks.picker.get()) do
      picker:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    expect(depth == 0, "jumps on the tag stack after three presses: " .. depth)
    expect(tostring(said):find("defined here", 1, true), "the message: " .. tostring(said))
    expect(
      listed and listed_depth == 0,
      ("a list of several: %s, %d on the tag stack"):format(tostring(listed), listed_depth)
    )
  end)

  -- With the mouse alone: the right click menu starts with the peek and the
  -- jump of the gtags keys, Neovim's own "Go to definition" there asking a
  -- language server only.
  check("gtags: the right click menu peeks and jumps to the definition clicked", function()
    local items = vim.fn.menu_info("PopUp").submenus or {}
    local peek = vim.fn.menu_info("PopUp.Peek definition", "n")
    local jump = vim.fn.menu_info("PopUp.Jump to definition", "n")
    expect(
      items[1] == "Peek definition" and items[2] == "Jump to definition",
      "the menu starts with: " .. table.concat(vim.list_slice(items, 1, 3), ", ")
    )
    expect(
      tostring(peek.rhs):find('require("taka.gtags").peek', 1, true),
      "Peek definition runs: " .. tostring(peek.rhs)
    )
    expect(
      tostring(jump.rhs):find('require("taka.gtags").jump', 1, true),
      "Jump to definition runs: " .. tostring(jump.rhs)
    )
  end)

  check("scoop: the tools run from their own folder, not through a shim or junction", function()
    local shims = vim.fs.joinpath(vim.env.SCOOP or vim.fs.joinpath(vim.env.USERPROFILE or "", "scoop"), "shims")
    local shimmed = {}
    for _, tool in ipairs({ "global", "gtags", "gtags-cscope", "ctags", "readtags", "rg" }) do
      if vim.uv.fs_stat(vim.fs.joinpath(shims, tool .. ".shim")) then
        shimmed[#shimmed + 1] = tool
      end
    end
    if #shimmed == 0 then
      skip("no scoop shims for these tools")
    end
    local function crosses_link(path)
      local parts = vim.split(path, "/", { plain = true })
      local at = parts[1]
      for index = 2, #parts do
        at = at .. "/" .. parts[index]
        local stat = vim.uv.fs_lstat(at)
        if stat and stat.type == "link" then
          return true
        end
      end
      return false
    end
    local through = {}
    for _, tool in ipairs(shimmed) do
      local found = vim.fs.normalize(vim.fn.exepath(tool))
      if found == "" or found:lower():find(vim.fs.normalize(shims):lower(), 1, true) or crosses_link(found) then
        through[#through + 1] = tool .. " = " .. found
      end
    end
    expect(#through == 0, "still through a shim or a junction: " .. table.concat(through, ", "))
  end)
  check("peek: opens without moving, follows a jump inside it, closes with Esc", function()
    need("gtags", "global")
    local dir = c_project()
    run({ "gtags" }, dir)
    vim.api.nvim_set_current_dir(dir)
    vim.cmd.edit(dir .. "/main.c")
    vim.fn.cursor(5, 12)
    local origin = vim.api.nvim_get_current_win()
    key("<leader>jp")()
    expect(
      vim.wait(15000, function()
        return #floats() == 1
      end, 20),
      "the peek window did not open"
    )
    expect(vim.api.nvim_win_get_cursor(origin)[1] == 5, "the cursor in the file moved")
    expect(
      vim.bo[vim.api.nvim_win_get_buf(floats()[1])].buftype == "nofile",
      "the peek shows a real file, not its scratch copy"
    )

    -- A jump key inside the peek must not load a file into the small window.
    local first = floats()[1]
    vim.fn.search("target_fn")
    press("<C-]>")
    vim.wait(15000, function()
      local open = floats()
      return #open == 1 and open[1] ~= first
    end, 20)
    local open = floats()
    local scratch = #open == 1 and vim.bo[vim.api.nvim_win_get_buf(open[1])].buftype == "nofile"
    press("<Esc>")
    vim.wait(500)
    local left = #floats()
    reset_editor()
    expect(#open == 1, "a jump inside the peek left " .. #open .. " floating windows")
    expect(scratch, "a jump inside the peek loaded a file into it")
    expect(left == 0, "Esc did not close the peek")
  end)
  -- The peek's room is the screen's, not the window's: from a short split at
  -- the bottom it was held to the few rows of that split while the screen
  -- above stood free. It may reach over the window above, and still leaves the
  -- line under the cursor in view.
  check("peek: from a short split, four tenths of the screen tall", function()
    need("gtags", "global")
    local dir = temp_dir()
    local body = { "int long_fn(int x)", "{" }
    for i = 1, 20 do
      body[#body + 1] = ("    x = x + %d;"):format(i)
    end
    body[#body + 1] = "    return x;"
    body[#body + 1] = "}"
    write(dir .. "/lib.c", body)
    write(dir .. "/main.c", { "int long_fn(int x);", "int main(void)", "{", "    return long_fn(1);", "}" })
    run({ "gtags" }, dir)
    -- Sixty rows, of which four tenths is twenty-four: the whole of long_fn.
    local lines = vim.o.lines
    vim.o.lines = 60
    vim.cmd.edit(dir .. "/main.c")
    vim.cmd("split")
    vim.cmd("resize 6")
    local origin = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 4, 12 })
    key("<leader>jp")()
    vim.wait(5000, function()
      return #floats() > 0
    end, 20)
    local peek = floats()[1]
    local height = peek and vim.api.nvim_win_get_height(peek)
    local top = peek and vim.fn.win_screenpos(peek)[1]
    local cursor_screen = vim.fn.win_screenpos(origin)[1] + 3
    local window_height = vim.api.nvim_win_get_height(origin)
    if peek then
      vim.api.nvim_win_close(peek, true)
    end
    reset_editor()
    vim.o.lines = lines
    expect(height, "no peek opened")
    expect(height == 24, ("the peek has %d rows on a screen of 60, not four tenths of it"):format(height))
    expect(height > window_height, ("the peek has %d rows, the window %d"):format(height, window_height))
    expect(
      cursor_screen < top - 1 or cursor_screen > top + height,
      ("the peek on rows %d to %d covers the cursor line, row %d"):format(top - 1, top + height, cursor_screen)
    )
  end)

  check("ctags: <leader>jB writes tags to the root of a tree that is not under version control", function()
    need(vim.g.gutentags_ctags_executable or "ctags")
    local dir = c_project()
    vim.api.nvim_set_current_dir(dir)
    vim.cmd("enew")
    key("<leader>jB")()
    local built = vim.wait(30000, function()
      return vim.uv.fs_stat(dir .. "/tags") ~= nil
    end, 50)
    vim.wait(500)
    local leftover = vim.uv.fs_stat(dir .. "/tags.temp") ~= nil
    local found = false
    if built then
      for _, line in ipairs(vim.fn.readfile(dir .. "/tags")) do
        found = found or line:find("^target_fn\t") ~= nil
      end
    end
    reset_editor()
    expect(built, "tags was not written to the project root")
    expect(not leftover, "tags.temp was left behind")
    expect(found, "the definition is not in the index")
  end)
  -- With no GTAGS the jump falls back to ctags. Several matches used to bring up
  -- Vim's numbered prompt; they belong in the same list the gtags results use.
  check("ctags fallback: one match is jumped to, several are listed", function()
    need(vim.g.gutentags_ctags_executable or "ctags")
    local dir = temp_dir()
    write(dir .. "/a.c", { "/* first */", "int dup_fn(void)", "{", "    return 1;", "}" })
    write(dir .. "/b.c", { "int dup_fn(void)", "{", "    return 2;", "}" })
    write(dir .. "/d.c", { "", "", "int only_fn(void)", "{", "    return 3;", "}" })
    write(dir .. "/c.c", { "int use(void)", "{", "    return dup_fn() + only_fn();", "}" })
    vim.api.nvim_set_current_dir(dir)
    vim.cmd("enew")
    key("<leader>jB")()
    expect(
      vim.wait(30000, function()
        return vim.uv.fs_stat(dir .. "/tags") ~= nil
      end, 50),
      "tags was not built"
    )
    vim.wait(500)
    local real_qflist = Snacks.picker.qflist
    Snacks.picker.qflist = function() end

    vim.cmd.edit(dir .. "/c.c")
    vim.fn.cursor(3, 12)
    local word_many = vim.fn.expand("<cword>")
    vim.fn.setqflist({})
    key("<C-]>")()
    vim.wait(3000, function()
      return #vim.fn.getqflist() > 0
    end, 20)
    local listed = vim.tbl_map(function(entry)
      return vim.fn.fnamemodify(vim.fn.bufname(entry.bufnr), ":t") .. ":" .. entry.lnum
    end, vim.fn.getqflist())
    table.sort(listed)

    vim.cmd.edit(dir .. "/c.c")
    vim.fn.cursor(3, 23)
    local word_one = vim.fn.expand("<cword>")
    key("<C-]>")()
    vim.wait(3000, function()
      return vim.fn.expand("%:t") == "d.c"
    end, 20)
    local landed = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")

    -- The peek finds what the jump finds: with no answer from gtags, as over
    -- an ssh session where global came back empty, it read the tags too.
    vim.cmd.edit(dir .. "/c.c")
    vim.fn.cursor(3, 23)
    key("<leader>jp")()
    local peeked
    vim.wait(3000, function()
      for _, win in ipairs(floats()) do
        local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        if vim.tbl_contains(line, "int only_fn(void)") then
          peeked = true
        end
      end
      return peeked
    end, 20)

    Snacks.picker.qflist = real_qflist
    reset_editor()
    expect(word_many == "dup_fn" and word_one == "only_fn", "the cursor was on " .. word_many .. " and " .. word_one)
    expect(table.concat(listed, " ") == "a.c:2 b.c:1", "listed: " .. table.concat(listed, " "))
    expect(landed == "d.c:3", "landed on " .. landed)
    expect(peeked, "the peek did not find what the jump found")
  end)
  -- Completion in C from GTAGS (lua/taka/gtags/complete.lua): the names of the
  -- project as a word is typed, and after `->` or `.` the members of the type
  -- before it, through typedefs, pointers, arrays, a union with no name and a
  -- global of another file. A type that cannot be told offers nothing.
  check("completion: project names, and the members after -> and . by type", function()
    need("gtags", "global")
    local dir = temp_dir()
    write(dir .. "/types.h", {
      "struct inner { int depth; char *label; };",
      "typedef struct outer {",
      "    struct inner in;",
      "    struct inner *next;",
      "    union { int as_int; float as_float; };",
      "    struct inner items[4];",
      "} OUTER;",
      "typedef OUTER ALIAS;",
      "enum colour { COLOUR_RED, COLOUR_BLUE };",
      "int outer_new(void);",
    })
    write(
      dir .. "/main.c",
      { '#include "types.h"', "ALIAS *the_global;", "int outer_new(void) { return COLOUR_RED; }" }
    )
    write(dir .. "/use.c", {
      '#include "types.h"',
      "int use(OUTER *o, int n)",
      "{",
      "    struct inner local;",
      "    if (n) {",
      "        ALIAS *aliased = o;",
      "        n++;",
      "    }",
      "    return 0;",
      "}",
    })
    run({ "gtags" }, dir)
    vim.cmd.edit(dir .. "/use.c")
    local complete = require("taka.gtags.complete")
    local function offered(text)
      vim.api.nvim_buf_set_lines(0, 6, 7, false, { text })
      local result, finished
      complete.candidates(0, 6, #text, function(r)
        result, finished = r, true
      end)
      vim.wait(10000, function()
        return finished
      end, 10)
      if not result then
        return "none"
      end
      local names = vim.tbl_map(function(item)
        return item.label
      end, result.items)
      table.sort(names)
      return (result.dot_on_pointer and "fix " or "") .. table.concat(names, ",")
    end
    local seen = {}
    for _, text in ipairs({
      "        o->",
      "        o.",
      "        o->next->",
      "        o->items[n + 1].",
      "        aliased->in.la",
      "        local.",
      "        the_global->",
      "        ((OUTER *)o)->",
      "        nothing->",
      "        outer_",
      "        COLOUR_",
    }) do
      seen[vim.trim(text)] = offered(text)
    end
    vim.cmd("bwipeout!")
    reset_editor()
    local outer = "as_float,as_int,in,items,next"
    local inner = "depth,label"
    for text, want in pairs({
      ["o->"] = outer,
      ["o."] = "fix " .. outer,
      ["o->next->"] = inner,
      ["o->items[n + 1]."] = inner,
      ["aliased->in.la"] = inner,
      ["local."] = inner,
      ["the_global->"] = outer,
      ["((OUTER *)o)->"] = "none",
      ["nothing->"] = "none",
      ["outer_"] = "outer_new",
      ["COLOUR_"] = "COLOUR_BLUE,COLOUR_RED",
    }) do
      expect(seen[text] == want, ("after %q: %s"):format(text, tostring(seen[text])))
    end
  end)

  -- A language server that completes knows the types the GTAGS completion
  -- reads from declarations: with one attached, the GTAGS source steps aside,
  -- and answers again once it is gone.
  check("completion: steps aside for a language server that completes", function()
    local dir = temp_dir()
    write(dir .. "/a.c", { "int main(void) { return 0; }" })
    vim.cmd.edit(dir .. "/a.c")
    local buf = vim.api.nvim_get_current_buf()
    local source = require("taka.gtags.blink").new()
    local before = source:enabled()
    -- A server in this process that says it completes, and does nothing else.
    local closing = false
    local id = vim.lsp.start({
      name = "completes",
      root_dir = dir,
      cmd = function(dispatchers)
        return {
          request = function(method, _, callback)
            if method == "initialize" then
              callback(nil, { capabilities = { completionProvider = {} } })
            elseif callback then
              callback(nil, nil)
            end
            return true, 1
          end,
          notify = function()
            return true
          end,
          is_closing = function()
            return closing
          end,
          terminate = function()
            closing = true
            dispatchers.on_exit(0, 15)
          end,
        }
      end,
    }, { bufnr = buf })
    local attached = vim.wait(5000, function()
      return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/completion" }) > 0
    end, 20)
    local during = source:enabled()
    vim.lsp.stop_client(id, true)
    vim.wait(5000, function()
      return source:enabled()
    end, 20)
    local after = source:enabled()
    vim.cmd("bwipeout!")
    reset_editor()
    expect(attached, "the server did not attach")
    expect(
      before and not during and after,
      ("enabled before/with/after the server: %s/%s/%s"):format(tostring(before), tostring(during), tostring(after))
    )
  end)

  check("status: what runs in the background is shown, then cleared", function()
    local activity = require("taka.lib.activity")
    -- The check before leaves its result on show for two seconds, and a result
    -- is a line that does not move.
    local idle = vim.wait(6000, function()
      return vim.g.background_activity == nil
    end, 50)
    expect(idle, "an earlier check is still shown as running: " .. tostring(vim.g.background_activity))
    local finished = activity.begin("test: something slow")
    local frames = {}
    vim.wait(700, function()
      frames[tostring(vim.g.background_activity)] = true
      return false
    end, 20)
    finished("done")
    local result = tostring(vim.g.background_activity)
    local cleared = vim.wait(4000, function()
      return vim.g.background_activity == nil
    end, 50)
    expect(vim.tbl_count(frames) >= 3, "the spinner did not move")
    expect(result:find("%(done%)"), "the result was not shown: " .. result)
    expect(cleared, "the statusline was not cleared")
  end)
end

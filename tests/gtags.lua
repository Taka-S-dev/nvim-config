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

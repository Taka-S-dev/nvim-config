-- The editor as configured: every file loads, gitsigns and :grep.
return function(T)
  local check, expect, temp_dir, write, need, run, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.need, T.run, T.reset_editor

  check("every config file parses and every plugin loads", function()
    -- A plugin file that does not parse is skipped by lazy.nvim with a message
    -- nobody reads in a headless run, and its plugin simply is not there.
    local config = vim.fn.stdpath("config")
    for _, file in ipairs(vim.fn.globpath(config, "lua/**/*.lua", false, true)) do
      local chunk, err = loadfile(file)
      expect(chunk ~= nil, tostring(err))
    end
    local failed = {}
    for name, plugin in pairs(require("lazy.core.config").plugins) do
      if plugin._.error then
        failed[#failed + 1] = name
      end
    end
    expect(#failed == 0, "failed to load: " .. table.concat(failed, ", "))
  end)
  -- core.autocrlf=true leaves CRLF on disk and LF in git, and git calls the file
  -- unchanged. It takes an .editorconfig asking for LF as well, as the Linux
  -- tree has: Neovim then switches the buffer to unix line endings after reading
  -- it, gitsigns compares that against text it expects to carry CRLF, and every
  -- line of a file nobody touched came out as changed. Without the .editorconfig
  -- the buffer stays dos and this check passes whatever the setting is.
  check("gitsigns: an untouched CRLF checkout has no change marks", function()
    need("git")
    local dir = temp_dir()
    run({ "git", "init", "-q" }, dir)
    run({ "git", "config", "core.autocrlf", "true" }, dir)
    local lines = {}
    for i = 1, 30 do
      lines[i] = ("int value_%d = %d;"):format(i, i)
    end
    write(dir .. "/sample.c", lines)
    write(dir .. "/.editorconfig", { "root = true", "", "[*]", "end_of_line = lf" })
    run({ "git", "add", "sample.c", ".editorconfig" }, dir)
    run({ "git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "sample" }, dir)
    vim.fn.delete(dir .. "/sample.c")
    run({ "git", "checkout", "--", "sample.c" }, dir)
    local file = assert(io.open(dir .. "/sample.c", "rb"))
    local raw = file:read("*a")
    file:close()
    expect(raw:find("\r\n", 1, true) ~= nil, "the checkout did not produce CRLF, so this check proves nothing")

    local gitsigns = require("gitsigns")
    local function marked()
      local hunks
      vim.wait(15000, function()
        hunks = gitsigns.get_hunks(0)
        return hunks ~= nil
      end, 100)
      expect(hunks ~= nil, "gitsigns never attached to the buffer")
      vim.wait(1000)
      local count = 0
      for _, hunk in ipairs(gitsigns.get_hunks(0) or {}) do
        count = count + math.max(hunk.added.count, hunk.removed.count)
      end
      return count
    end

    vim.cmd.edit(dir .. "/sample.c")
    local fileformat = vim.bo.fileformat
    local untouched = marked()
    vim.api.nvim_buf_set_lines(0, 4, 5, false, { "int value_5 = 500;" })
    gitsigns.refresh()
    vim.wait(1000)
    local after_edit = marked()
    local foreign = 0
    for _, sign in ipairs(vim.fn.sign_getplaced(vim.api.nvim_get_current_buf(), { group = "*" })[1].signs) do
      foreign = foreign + (sign.name:find("^Signify") and 1 or 0)
    end
    -- Let go of the repository before it is removed from under the watcher.
    gitsigns.detach_all()
    reset_editor()
    expect(fileformat == "unix", "the buffer stayed " .. fileformat .. ", so this check proves nothing")
    expect(untouched == 0, ("%d of 30 untouched lines are marked as changed"):format(untouched))
    expect(after_edit >= 1, "a real edit is no longer marked")
    expect(foreign == 0, ("%d svn marks in a git checkout"):format(foreign))
  end)
  -- Run in a child with a time limit: the failure being guarded against is a
  -- hang, and a hang here would take the whole run with it.
  check(":grep with no path returns, and leaves index files and backups out", function()
    need("rg")
    local dir = temp_dir()
    write(dir .. "/src/a.c", { "int needle_for_the_test = 1;" })
    write(dir .. "/tags", { "needle_for_the_test\tsrc/a.c\t/^int needle_for_the_test/" })
    write(dir .. "/src/a.BAK", { "int needle_for_the_test = 1;" })
    write(dir .. "/cscope.out", { "needle_for_the_test" })
    local out = dir .. "/result.json"
    local script = ([[lua vim.fn.writefile({ vim.json.encode(vim.tbl_map(function(e) return vim.fn.fnamemodify(vim.fn.bufname(e.bufnr), ":t") end, vim.fn.getqflist())) }, %q)]]):format(
      out
    )
    local child = vim
      .system(
        { vim.v.progpath, "--headless", "-n", "-c", "silent grep needle_for_the_test", "-c", script, "-c", "qa!" },
        { cwd = dir, text = true }
      )
      :wait(40000)
    expect(
      child.code == 0 and vim.uv.fs_stat(out) ~= nil,
      ":grep did not return within 40 s (exit " .. tostring(child.code) .. ")"
    )
    local names = vim.json.decode(table.concat(vim.fn.readfile(out), ""))
    expect(vim.tbl_contains(names, "a.c"), "the source file was not found: " .. vim.inspect(names))
    for _, unwanted in ipairs({ "tags", "a.BAK", "cscope.out" }) do
      expect(not vim.tbl_contains(names, unwanted), unwanted .. " turned up among the matches")
    end
  end)

  -- The terminal of <C-/>, hidden and shown again, came back at four tenths of
  -- the editor whatever height it had been given
  -- (lua/plugins/snacks-terminal.lua).
  check("terminal: shown again at the height it was hidden at", function()
    local term = Snacks.terminal.open(nil, { cwd = vim.fn.getcwd() })
    local first = vim.api.nvim_win_get_height(term.win)
    vim.api.nvim_win_set_height(term.win, 7)
    term:hide()
    term:show()
    local again = term.win and vim.api.nvim_win_is_valid(term.win) and vim.api.nvim_win_get_height(term.win)
    term:close()
    -- The terminal starts insert mode as it is entered; the checks after this
    -- one press keys in normal mode.
    vim.cmd.stopinsert()
    vim.wait(100)
    reset_editor()
    expect(first ~= 7, "the terminal opened at 7 rows already")
    expect(again == 7, "shown again at " .. tostring(again) .. " rows")
  end)
end

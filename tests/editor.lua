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
  -- An installed copilot-language-server was started for every file, as
  -- mason-lspconfig starts whatever mason holds (lua/plugins/lsp.lua).
  check("lsp: copilot is not started though it is installed, lua_ls is", function()
    if not vim.uv.fs_stat(vim.fn.stdpath("data") .. "/mason/packages/copilot-language-server") then
      T.skip("copilot-language-server is not installed through mason")
    end
    require("lazy").load({ plugins = { "nvim-lspconfig" } })
    local copilot, lua_ls = vim.lsp.is_enabled("copilot"), vim.lsp.is_enabled("lua_ls")
    expect(not copilot, "copilot is enabled")
    expect(lua_ls, "lua_ls is not enabled")
  end)
  -- Space typed in Normal mode with the Japanese input method on came in as a
  -- full-width space, and <leader> did nothing. The input method is turned off
  -- on leaving Insert mode or the command line (lua/taka/ime.lua); with no
  -- screen, as here, nothing is sent to the window in front.
  check("ime: turned off on every way out of Insert mode and the command line", function()
    if vim.fn.has("win32") == 0 then
      T.skip("the input method is turned off on Windows only")
    end
    local ime = require("taka.ime")
    local off, calls = ime.off, 0
    ime.off = function()
      calls = calls + 1
    end
    -- Each change of mode, and whether the input method is turned off: out of
    -- Insert mode, by Esc or by Ctrl-C, which sends no InsertLeave; out of the
    -- command line and Replace mode; not into the completion menu, Ctrl-O's
    -- one command, or the command line from Insert mode.
    local changes = { "i:n", "c:n", "R:n", "i:ic", "i:niI", "ic:i", "n:i", "i:c" }
    local seen = {}
    local ok, err = pcall(function()
      for _, change in ipairs(changes) do
        local before = calls
        vim.api.nvim_exec_autocmds("ModeChanged", { pattern = change })
        seen[#seen + 1] = change .. "=" .. (calls > before and "off" or "-")
      end
    end)
    ime.off = off
    expect(ok, tostring(err))
    expect(ime.available(), "the Windows API could not be loaded")
    expect(
      table.concat(seen, " ") == "i:n=off c:n=off R:n=off i:ic=- i:niI=- ic:i=- n:i=- i:c=-",
      "turned off on: " .. table.concat(seen, " ")
    )
  end)
  -- <leader>ff and <leader>sg search the folder opened, the one the file tree
  -- shows. LazyVim looked up from the file for a .git, and a project with none
  -- of its own, in a folder of checkouts under one .git, searched them all.
  check("root: the files and the grep search the folder opened", function()
    local dir = temp_dir()
    vim.fn.mkdir(dir .. "/.git")
    write(dir .. "/openssl/GTAGS", { "" })
    write(dir .. "/openssl/ssl/a.c", { "int a;" })
    write(dir .. "/linux/b.c", { "int b;" })
    local cwd = vim.fn.getcwd()
    local root
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir .. "/openssl")
      vim.cmd.edit(dir .. "/openssl/ssl/a.c")
      root = LazyVim.root()
    end)
    vim.cmd("silent! %bwipeout!")
    vim.api.nvim_set_current_dir(cwd)
    expect(ok, tostring(err))
    expect(
      root and vim.fs.normalize(root):lower() == vim.fs.normalize(dir .. "/openssl"):lower(),
      "the root was " .. tostring(root)
    )
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

  -- The file tree follows the file shown in the code: switched to a file in a
  -- folder not yet open, the tree opened the folder and left its cursor rows
  -- away. <leader>fl brings it back to the file after the tree was scrolled.
  check("explorer: the tree's cursor follows the file, and <leader>fl finds it", function()
    local dir = temp_dir()
    for _, folder in ipairs({ "a", "b", "c", "d" }) do
      for number = 1, 5 do
        T.write(("%s/%s/f%d.c"):format(dir, folder, number), { "int x;" })
      end
    end
    local seen = {}
    local explorer
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/a/f1.c")
      local code = vim.api.nvim_get_current_win()
      Snacks.explorer()
      vim.wait(2000, function()
        explorer = Snacks.picker.get({ source = "explorer" })[1]
        return explorer and explorer:current() ~= nil
      end, 20)
      -- Settled, as a tree is before a reader goes on to another file: snacks
      -- puts the cursor on the file the tree was opened from once it has read
      -- the folders, which a switch made at once came before.
      vim.wait(500)
      vim.api.nvim_set_current_win(code)
      local function current()
        local item = explorer:current()
        return item and vim.fs.basename(vim.fs.dirname(item.file)) .. "/" .. vim.fs.basename(item.file)
      end
      vim.cmd.edit(dir .. "/d/f4.c")
      vim.wait(2000, function()
        return current() == "d/f4.c"
      end, 20)
      seen.followed = current()
      explorer.list:view(1)
      vim.wait(100)
      T.key("<leader>fl")()
      vim.wait(2000, function()
        return current() == "d/f4.c"
      end, 20)
      seen.found = current()
    end)
    if explorer and not explorer.closed then
      explorer:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.followed == "d/f4.c", "the tree's cursor is on " .. tostring(seen.followed))
    expect(seen.found == "d/f4.c", "<leader>fl left the cursor on " .. tostring(seen.found))
  end)

  -- A path with a line number, written the ways a person or a tool writes it,
  -- is opened at that line with <leader>fo from the clipboard; one not found
  -- is looked for by the end of its path in the list of files.
  check("open path: a path:line copied from anywhere opens at its line", function()
    local open_path = require("taka.open_path")
    local forms = {}
    for _, text in ipairs({
      "src/a.c l12",
      "src/a.c:12",
      "src/a.c:12:5",
      "`src/a.c(12)`",
      "src/a.c#L12",
      "src/a.c line 12",
      "src/a.c 12",
      "C:/x/a.c:12",
    }) do
      local path, line = open_path.parse(text)
      forms[#forms + 1] = path .. "|" .. tostring(line)
    end
    local dir = temp_dir()
    local lines = {}
    for i = 1, 30 do
      lines[i] = ("int v%d;"):format(i)
    end
    T.write(dir .. "/src/a.c", lines)
    local seen = {}
    local register = vim.fn.getreg("+")
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.fn.setreg("+", "src/a.c l12")
      T.key("<leader>fo")()
      seen.opened = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      -- A path written from the root of the project the current file is in,
      -- one outside the cwd.
      local other = temp_dir()
      T.write(other .. "/GTAGS", { "" })
      T.write(other .. "/lib/b.c", lines)
      vim.cmd.edit(other .. "/lib/b.c")
      vim.fn.setreg("+", "lib/b.c:7")
      T.key("<leader>fo")()
      seen.other = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      vim.fn.setreg("+", "elsewhere/a.c:20")
      T.key("<leader>fo")()
      local picker
      vim.wait(2000, function()
        picker = Snacks.picker.get({ source = "files" })[1]
        return picker ~= nil
      end, 20)
      seen.query = picker and picker.input:get()
    end)
    -- The list is closed whatever happened, so it is left over the checks
    -- that come after.
    for _, picker in ipairs(Snacks.picker.get({ source = "files" })) do
      picker:close()
    end
    pcall(vim.fn.setreg, "+", register)
    reset_editor()
    expect(ok, tostring(err))
    expect(
      vim.deep_equal(forms, {
        "src/a.c|12",
        "src/a.c|12",
        "src/a.c|12",
        "src/a.c|12",
        "src/a.c|12",
        "src/a.c|12",
        "src/a.c|12",
        "C:/x/a.c|12",
      }),
      "read as: " .. vim.inspect(forms)
    )
    expect(seen.opened == "a.c:12", "opened at " .. tostring(seen.opened))
    expect(seen.other == "b.c:7", "from the project of the file, opened at " .. tostring(seen.other))
    expect(seen.query == "elsewhere/a.c:20", "the list was given " .. tostring(seen.query))
  end)

  -- A path pasted into the list of files as Windows writes it, with back
  -- slashes or from the drive, finds the file and opens it at its line: it
  -- matched nothing.
  check("files: a path with back slashes, pasted with its line, is found and opened there", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 20 do
      lines[i] = ("int w%d;"):format(i)
    end
    T.write(dir .. "/inc/deep/b.h", lines)
    T.write(dir .. "/other.c", { "int x;" })
    local seen = {}
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      for _, pattern in ipairs({ [[deep\b.h:7]], (dir:gsub("/", "\\")) .. [[\inc\deep\b.h:7]] }) do
        local picker = Snacks.picker.files({ pattern = pattern })
        vim.wait(3000, function()
          return #picker:items() == 1
        end, 20)
        seen[#seen + 1] = #picker:items()
        picker:action("confirm")
        vim.wait(1000, function()
          return vim.fn.expand("%:t") == "b.h"
        end, 20)
        seen[#seen + 1] = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
        vim.cmd("enew")
      end
    end)
    for _, picker in ipairs(Snacks.picker.get({ source = "files" })) do
      picker:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    expect(vim.deep_equal(seen, { 1, "b.h:7", 1, "b.h:7" }), "found and opened: " .. vim.inspect(seen))
  end)

  -- The line typed after the file in the list of files moves the preview when
  -- only the line changes: snacks kept the preview on the first line typed.
  check("files: changing the line typed after the file moves the preview", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 60 do
      lines[i] = ("int p%d;"):format(i)
    end
    T.write(dir .. "/c.c", lines)
    local seen = {}
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      local picker = Snacks.picker.files({ pattern = "c.c:13" })
      local function preview_line()
        local win = picker.preview and picker.preview.win and picker.preview.win.win
        return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1]
      end
      vim.wait(3000, function()
        return preview_line() == 13
      end, 20)
      seen[#seen + 1] = preview_line()
      -- Typed as the panel checks do: a headless run has no keys to type.
      local input = picker.input.win.buf
      vim.api.nvim_buf_set_lines(input, 0, -1, false, { "c.c:45" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = input })
      vim.wait(3000, function()
        return preview_line() == 45
      end, 20)
      seen[#seen + 1] = preview_line()
    end)
    for _, picker in ipairs(Snacks.picker.get({ source = "files" })) do
      picker:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    expect(vim.deep_equal(seen, { 13, 45 }), "the preview was on lines " .. vim.inspect(seen))
  end)

  -- The find bar of <leader>sf: what is typed is found as it is, counted, and
  -- gone through with the keys or the buttons; closed, n goes on with it.
  check("find: the bar finds what is typed, counts it and steps through it", function()
    local find = require("taka.find")
    local dir = temp_dir()
    T.write(dir .. "/f.c", { "int a.b;", "int x;", "int A.B;", "int y;", "int a.b2;" })
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/f.c")
      local code = vim.api.nvim_get_current_win()
      T.key("<leader>sf")()
      local function type_in(text)
        local shown = find.shown()
        vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(shown.win), 0, -1, false, { text })
        vim.api.nvim_exec_autocmds("TextChangedI", { buffer = vim.api.nvim_win_get_buf(shown.win) })
      end
      local function state()
        local shown = find.shown()
        return vim.trim(shown.right:match("^[^%s]+") or "") .. "@" .. vim.api.nvim_win_get_cursor(code)[1]
      end
      -- a.b is the text, not a pattern: a.b2 matches, aXb would not; lower case
      -- matches A.B too.
      type_in("a.b")
      seen[#seen + 1] = state()
      find.go(1)
      seen[#seen + 1] = state()
      find.go(-1)
      seen[#seen + 1] = state()
      -- A capital matches the case typed.
      type_in("A.B")
      seen[#seen + 1] = state()
      -- The bar emptied puts the matches out; they were left lit.
      vim.wait(50)
      local lit = vim.v.hlsearch
      type_in("")
      vim.wait(50)
      seen[#seen + 1] = lit .. "->" .. vim.v.hlsearch
      type_in("A.B")
      local width = vim.api.nvim_win_get_width(find.shown().win)
      seen[#seen + 1] = table.concat({
        (find.button_at(width) or "nil"),
        (find.button_at(width - 3) or "nil"),
        (find.button_at(width - 6) or "nil"),
        (find.button_at(width - 10) or "nil"),
        (find.button_at(width - 14) or "nil"),
        (find.button_at(2) or "nil"),
      }, ",")
      -- The two ways of matching, by their keys: whole words leave a.b2 out,
      -- and the case typed then leaves A.B out too.
      local bar_keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(find.shown().win), "i")) do
        bar_keys[map.lhsraw] = map.callback
      end
      local function count()
        return vim.trim(find.shown().right:match("^[^%s]+") or "")
      end
      type_in("a.b")
      local counts = { count() }
      bar_keys[vim.keycode("<A-w>")]()
      counts[#counts + 1] = count()
      bar_keys[vim.keycode("<A-c>")]()
      counts[#counts + 1] = count()
      bar_keys[vim.keycode("<A-c>")]()
      bar_keys[vim.keycode("<A-w>")]()
      counts[#counts + 1] = count()
      seen[#seen + 1] = table.concat(counts, ",")
      type_in("A.B")
      -- While the bar is open the file does not scroll smoothly, which carried
      -- the cursor to a match a line at a time under quick clicks; quick
      -- clicks on the bar are its own, each a press.
      local bar_buf = vim.api.nvim_win_get_buf(find.shown().win)
      local quick = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bar_buf, "i")) do
        quick[map.lhs] = map.callback ~= nil
      end
      seen[#seen + 1] = tostring(vim.b[vim.api.nvim_win_get_buf(code)].snacks_scroll)
        .. ":"
        .. tostring(quick["<2-LeftMouse>"] and quick["<4-LeftMouse>"])
      find.close()
      seen[#seen + 1] = tostring(find.shown())
        .. ":"
        .. vim.v.hlsearch
        .. ":"
        .. tostring(vim.b[vim.api.nvim_win_get_buf(code)].snacks_scroll)
      vim.api.nvim_win_set_cursor(code, { 1, 0 })
      vim.cmd("normal! n")
      seen[#seen + 1] = vim.api.nvim_win_get_cursor(code)[1]
    end)
    pcall(find.close)
    find.options.case, find.options.word = false, false
    vim.cmd("stopinsert")
    reset_editor()
    expect(ok, tostring(err))
    expect(
      vim.deep_equal(seen, {
        "1/3@1",
        "2/3@3",
        "1/3@1",
        "1/1@3",
        "1->0",
        "close,next,previous,word,case,nil",
        "1/3,1/2,1/1,1/3",
        "false:true",
        "nil:0:nil",
        3,
      }),
      "the bar: " .. vim.inspect(seen)
    )
  end)
end

-- SVN: change marks, the <leader>v tools and the blame (lua/taka/svn/).
return function(T)
  local spawned, check, expect, temp_dir, write, need, run, key, press, reset_editor =
    T.spawned, T.check, T.expect, T.temp_dir, T.write, T.need, T.run, T.key, T.press, T.reset_editor

  -- vim-signify marks the changes of a Subversion working copy, and it is kept
  -- to svn so that a git checkout keeps gitsigns' marks alone. The marks come
  -- from a BufRead autocmd, which a plugin loaded lazily registered too late.
  check("svn: a changed working copy shows change marks, a git checkout none of them", function()
    need("svn", "svnadmin")
    local dir = temp_dir()
    run({ "svnadmin", "create", dir .. "/repo" })
    local url = "file:///" .. dir:gsub("^/", "") .. "/repo"
    run({ "svn", "-q", "checkout", url, dir .. "/wc" })
    write(dir .. "/wc/a.c", { "int a;", "int b;", "int c;", "int d;", "int e;" })
    run({ "svn", "-q", "add", "a.c" }, dir .. "/wc")
    run({ "svn", "-q", "commit", "-m", "base" }, dir .. "/wc")
    write(dir .. "/wc/a.c", { "int a;", "int B;", "int c;", "int d;", "int e;", "int f;" })
    -- In a child, so that the changed file is the first file the session
    -- reads: that is where a plugin loaded on the first read came too late.
    local out = dir .. "/signs.txt"
    local script = ([[lua vim.wait(8000, function() return #vim.fn.sign_getplaced(1, { group = "*" })[1].signs > 0 end, 100) local rows = {} for _, s in ipairs(vim.fn.sign_getplaced(1, { group = "*" })[1].signs) do rows[#rows + 1] = s.lnum .. ":" .. s.name end local looks = {} for _, name in ipairs({ "SignifyAdd", "SignifyChange" }) do local d = vim.fn.sign_getdefined(name)[1] looks[#looks + 1] = vim.trim(d.text) .. (vim.api.nvim_get_hl(0, { name = d.texthl, link = false }).fg and " coloured" or " grey") end vim.fn.writefile({ table.concat(rows, " "), table.concat(looks, ", ") }, %q)]]):format(
      out
    )
    local child = vim
      .system({ vim.v.progpath, "--headless", "-n", dir .. "/wc/a.c", "-c", script, "-c", "qa!" }, { cwd = dir, text = true })
      :wait(40000)
    expect(
      child.code == 0 and vim.uv.fs_stat(out) ~= nil,
      "the child did not finish (exit " .. tostring(child.code) .. ")"
    )
    local written = vim.fn.readfile(out)
    local svn_marks = written[1] or ""
    expect(svn_marks == "2:SignifyChange 6:SignifyAdd", "marks on the first file read: " .. svn_marks)
    -- A bar in a colour of its own, as gitsigns draws: the plugin's letters
    -- on a background tint could hardly be seen.
    local looks = written[2] or ""
    expect(looks == "▎ coloured, ▎ coloured", "the marks look like: " .. looks)
    expect(vim.fn.maparg("]h", "n") ~= "", "]h is not mapped")
  end)
  -- Without svn nothing of it is there: vim-signify is not loaded and the
  -- <leader>v keys do not exist. Checked in a child whose PATH has every
  -- directory holding svn taken out, so it runs whether svn is installed or not.
  check("svn: without svn on the PATH, neither vim-signify nor the <leader>v keys", function()
    local dir = temp_dir()
    local sep = vim.fn.has("win32") == 1 and ";" or ":"
    local exe = vim.fn.has("win32") == 1 and "svn.exe" or "svn"
    local kept = {}
    for _, entry in ipairs(vim.split(vim.env.PATH or "", sep, { plain = true })) do
      if entry ~= "" and not vim.uv.fs_stat(entry .. "/" .. exe) then
        kept[#kept + 1] = entry
      end
    end
    local out = dir .. "/state.txt"
    local script = ([[lua vim.fn.writefile({ tostring(vim.fn.executable("svn")), tostring(vim.fn.exists(":SignifyDiff")), vim.fn.maparg(" vs", "n") }, %q)]]):format(
      out
    )
    local child = vim
      .system(
        { vim.v.progpath, "--headless", "-n", "-c", script, "-c", "qa!" },
        { cwd = dir, text = true, env = { PATH = table.concat(kept, sep) } }
      )
      :wait(40000)
    expect(
      child.code == 0 and vim.uv.fs_stat(out) ~= nil,
      "the child did not finish (exit " .. tostring(child.code) .. ")"
    )
    local state = vim.fn.readfile(out)
    expect(state[1] == "0", "svn is still on the child's PATH, so this check proves nothing")
    expect(state[2] == "0", "vim-signify is loaded without svn")
    expect((state[3] or "") == "", "<leader>vs is mapped without svn")
  end)
  -- The <leader>v tools read the working copy and the repository: status into
  -- the quickfix list, a revision side by side, the files a revision changed
  -- under a folder, including one it deleted, and a hunk put back only when
  -- the question is answered yes.
  -- Blame, shown only when asked: the rows line up with a file edited since
  -- the update, a second look asks the repository nothing, the two windows
  -- stay level, Enter gives the revision's message, and putting it away gives
  -- the file its wrap back. A headless run fires no WinScrolled, so what it
  -- would call is called here.
  check("svn: blame beside the file, lined up with local edits, asked for once", function()
    need("svn", "svnadmin")
    local blame = require("taka.svn.blame")
    local dir = temp_dir()
    run({ "svnadmin", "create", dir .. "/repo" })
    local url = "file:///" .. dir:gsub("^/", "") .. "/repo"
    local wc = dir .. "/wc"
    run({ "svn", "-q", "checkout", url, wc })
    local lines = {}
    for i = 1, 80 do
      lines[i] = ("int a%d;"):format(i)
    end
    write(wc .. "/a.c", lines)
    run({ "svn", "-q", "add", "a.c" }, wc)
    run({ "svn", "-q", "commit", "--username", "alice", "-m", "add a" }, wc)
    lines[2] = "int B2;"
    write(wc .. "/a.c", lines)
    run({ "svn", "-q", "commit", "--username", "bob", "-m", "change a2" }, wc)
    write(wc .. "/b.c", { "int b1;", "int b2;" })
    run({ "svn", "-q", "add", "b.c" }, wc)
    run({ "svn", "-q", "commit", "--username", "carol", "-m", "add b" }, wc)
    run({ "svn", "-q", "update" }, wc)
    -- Since the update: a line added at the top, and the third line edited.
    table.insert(lines, 1, "int top;")
    lines[4] = "int A3;"
    write(wc .. "/a.c", lines)
    local seen = {}
    local notify = vim.notify
    local ok, err = pcall(function()
      vim.cmd.edit(wc .. "/a.c")
      local win = vim.api.nvim_get_current_win()
      vim.wo.wrap = true
      local function shown()
        vim.wait(10000, function()
          return #blame.lines(win) > 0
        end, 20)
        return vim.tbl_map(function(row)
          return row:match("^r%d+%s+%S+") or row
        end, vim.list_slice(blame.lines(win), 1, 5))
      end
      blame.toggle(win)
      seen.rows = table.concat(shown(), " | ")
      local blame_win = blame.window(win)
      -- The rows of the revision the cursor is on are marked, beside the file
      -- and in its line numbers: bob's one line, then alice's 78.
      local function marked_on(line)
        vim.api.nvim_win_set_cursor(win, { line, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
        return blame.marked(win)
      end
      seen.bob = marked_on(3)
      -- A cursor dragged by a scroll is no line chosen: the marking stays.
      vim.api.nvim_feedkeys(vim.keycode("<C-e>"), "x", false)
      seen.scrolled = marked_on(2)
      vim.api.nvim_feedkeys("j", "x", false)
      local alice = marked_on(2)
      seen.alice = select(2, alice:gsub("%d+", "")) .. " " .. alice:sub(1, 7)
      seen.edited = marked_on(1)
      -- No smooth scrolling in either while the blame is open: stepped, the
      -- one following trails the one scrolled.
      local animates = Snacks.config.get("scroll", {}).filter
      seen.animates = tostring(animates(vim.api.nvim_win_get_buf(win)))
        .. "/"
        .. tostring(animates(vim.api.nvim_win_get_buf(blame_win)))
      vim.fn.winrestview({ topline = 40, lnum = 40 })
      blame.follow(win)
      seen.followed = vim.api.nvim_win_call(blame_win, function()
        return vim.fn.line("w0")
      end)
      vim.api.nvim_win_call(blame_win, function()
        vim.fn.winrestview({ topline = 10 })
      end)
      blame.follow(blame_win)
      seen.led = vim.fn.line("w0")
      vim.notify = function(message)
        seen.message = message
      end
      vim.api.nvim_set_current_win(blame_win)
      vim.api.nvim_win_set_cursor(blame_win, { 1, 0 })
      -- Stepped to in the blame, a row puts the file's cursor on its line.
      press("2j")
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(blame_win) })
      seen.cursor = vim.api.nvim_win_get_cursor(win)[1]
      press("<CR>")
      vim.wait(10000, function()
        return seen.message ~= nil
      end, 20)
      vim.api.nvim_set_current_win(win)
      blame.toggle(win)
      seen.closed = blame.window(win) == nil and vim.wo.wrap
      local before = spawned.svn or 0
      blame.toggle(win)
      seen.again = table.concat(shown(), " | ")
      vim.wait(1000)
      seen.processes = (spawned.svn or 0) - before
      -- Another file in the window: the blame goes to it, says so where
      -- there is none, and comes back to the first without asking again.
      local function rows_now(want)
        vim.wait(10000, function()
          return blame.lines(win)[1] == want
        end, 20)
        return table.concat(blame.lines(win), " | "):gsub("%s+%d%d%d%d%-%d%d%-%d%d", "")
      end
      vim.cmd.edit(wc .. "/b.c")
      vim.wait(10000, function()
        return (blame.lines(win)[1] or ""):match("^r%d")
      end, 20)
      seen.other = table.concat(blame.lines(win), " | "):gsub("%s+%d%d%d%d%-%d%d%-%d%d", "")
      vim.cmd("enew")
      seen.none = rows_now("(no file)")
      vim.cmd.edit(wc .. "/a.c")
      vim.wait(10000, function()
        return #blame.lines(win) > 2
      end, 20)
      seen.back = table.concat(vim.list_slice(blame.lines(win), 1, 3), " | "):gsub("%s+%d%d%d%d%-%d%d%-%d%d", "")
      blame.toggle(win)
      seen.animates_after = tostring(animates(vim.api.nvim_win_get_buf(win)))
    end)
    vim.notify = notify
    reset_editor()
    expect(ok, tostring(err))
    local want = "(local) | r1     alice | r2     bob | (local) | r1     alice"
    expect(seen.rows == want, "rows: " .. tostring(seen.rows))
    expect(seen.animates == "false/false", "smooth scrolling beside the blame, file/blame: " .. tostring(seen.animates))
    expect(
      seen.animates_after == "true",
      "smooth scrolling once the blame is put away: " .. tostring(seen.animates_after)
    )
    expect(seen.bob == "3 / 3", "marked with the cursor on bob's line: " .. tostring(seen.bob))
    expect(seen.alice == "156 2,5,6,7", "marked with the cursor on alice's: " .. tostring(seen.alice))
    expect(seen.scrolled == "3 / 3", "marked after a scroll moved the cursor: " .. tostring(seen.scrolled))
    expect(seen.edited == " / ", "marked with the cursor on a line edited since: " .. tostring(seen.edited))
    expect(seen.followed == 40, "the blame went to " .. tostring(seen.followed) .. ", not 40")
    expect(seen.led == 10, "the file went to " .. tostring(seen.led) .. ", not 10")
    expect(seen.cursor == 3, "a row stepped to in the blame put the file at line " .. tostring(seen.cursor))
    expect(tostring(seen.message):find("change a2", 1, true), "Enter on bob's row: " .. tostring(seen.message))
    expect(seen.closed == true, "put away, the window is not as it was")
    expect(seen.again == want, "shown again: " .. tostring(seen.again))
    expect(seen.processes == 1, ("shown again, svn ran %d times, not once for the base"):format(seen.processes))
    expect(seen.other == "r3     carol | r3     carol", "beside b.c: " .. tostring(seen.other))
    expect(seen.none == "(no file)", "beside a buffer with no file: " .. tostring(seen.none))
    expect(seen.back == "(local) | r1     alice | r2     bob", "back beside a.c: " .. tostring(seen.back))
  end)
  check("svn: status, revision diffs and the hunk undo", function()
    need("svn", "svnadmin")
    local svn = require("taka.svn")
    local dir = temp_dir()
    run({ "svnadmin", "create", dir .. "/repo" })
    local url = "file:///" .. dir:gsub("^/", "") .. "/repo"
    local wc = dir .. "/wc"
    run({ "svn", "-q", "checkout", url, wc })
    write(wc .. "/src/a.c", { "int a1;", "int a2;", "int a3;" })
    write(wc .. "/src/b.c", { "int b;" })
    -- Outside src/, for a log that lists what a revision changed elsewhere.
    write(wc .. "/top.txt", { "top" })
    run({ "svn", "-q", "add", "src", "top.txt" }, wc)
    run({ "svn", "-q", "commit", "-m", "add a and b" }, wc)
    write(wc .. "/src/a.c", { "int a1;", "int A2;", "int a3;" })
    run({ "svn", "-q", "commit", "-m", "change a2" }, wc)
    write(wc .. "/src/c.c", { "int c;" })
    run({ "svn", "-q", "add", "src/c.c" }, wc)
    run({ "svn", "-q", "rm", "src/b.c" }, wc)
    run({ "svn", "-q", "commit", "-m", "add c, drop b" }, wc)
    run({ "svn", "-q", "update" }, wc)
    write(wc .. "/src/a.c", { "int a1;", "int A2;", "int a3;", "int a4;" })
    write(wc .. "/.cache/state", { "x" })
    -- Ahead of src/ by name, behind it by state.
    write(wc .. "/0new.txt", { "x" })
    local seen = {}
    local confirm = vim.fn.confirm
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(wc)
      svn.status()
      vim.wait(8000, function()
        return #vim.fn.getqflist() > 0
      end, 50)
      local listed = {}
      for _, entry in ipairs(vim.fn.getqflist()) do
        listed[#listed + 1] = entry.text .. ":" .. vim.fn.fnamemodify(vim.fn.bufname(entry.bufnr), ":t")
      end
      seen.status = table.concat(listed, " ")
      vim.wait(2000, function()
        return vim.bo.filetype == "qf"
      end, 20)
      seen.shown = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), " | ")
      vim.wait(2000, function()
        return vim.fn.synIDattr(vim.fn.synID(2, 1, 1), "name") ~= "qfFileName"
      end, 20)
      seen.colours = vim.fn.synIDattr(vim.fn.synID(1, 1, 1), "name")
        .. " "
        .. vim.fn.synIDattr(vim.fn.synID(2, 1, 1), "name")
      vim.cmd("cclose")

      -- From the file tree, the folder under the cursor.
      local tree = Snacks.explorer()
      -- The tree lists itself again as it settles, so the cursor is put on
      -- src until it stays there.
      local function on_src()
        local current = tree:current()
        return current ~= nil and vim.fs.basename(current.file) == "src"
      end
      vim.wait(5000, function()
        for index, item in ipairs(tree.list.items) do
          if vim.fs.basename(item.file) == "src" then
            tree.list:view(index)
          end
        end
        return tree.list.win:valid() and on_src()
      end, 50)
      vim.wait(300)
      tree:focus("list")
      seen.tree_cursor = tree:current() and vim.fs.basename(tree:current().file)
      vim.fn.setqflist({})
      key("<leader>vs")()
      vim.wait(8000, function()
        return vim.bo.filetype == "qf"
      end, 20)
      seen.tree = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), " | ")
      vim.cmd("cclose")
      tree:close()

      -- The log, in a tab of its own: a revision opened lists the files it
      -- changed, and a file chosen is shown side by side left of the list.
      local tabs = #vim.api.nvim_list_tabpages()
      local function log_of(path)
        svn.history(path)
        local log
        vim.wait(8000, function()
          log = Snacks.picker.get({ source = "svn_log" })[1]
          return log ~= nil and #log.list.items > 0
        end, 50)
        return log
      end
      local function open_revision(log, rev)
        for index, item in ipairs(log.list.items) do
          if item.kind == "rev" and item.entry.rev == rev then
            log.list:view(index)
          end
        end
        log:action("confirm")
        local files = {}
        vim.wait(3000, function()
          files = {}
          for _, item in ipairs(log.list.items) do
            if item.kind == "file" and item.entry.rev == rev then
              files[#files + 1] = item.action .. ":" .. item.name .. (item.inside and "" or "(outside)")
            end
          end
          return #files > 0
        end, 20)
        return table.concat(files, " ")
      end
      local function show(log, rev, name)
        for index, item in ipairs(log.list.items) do
          if item.kind == "file" and item.entry.rev == rev and item.name == name then
            log.list:view(index)
          end
        end
        log:action("confirm")
        local sides = {}
        vim.wait(8000, function()
          sides = {}
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.wo[win].diff then
              sides[#sides + 1] = {
                col = vim.api.nvim_win_get_position(win)[2],
                name = vim.fs.basename(vim.api.nvim_buf_get_name(buf)),
                text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ","),
                -- The heading as it reads, its colours left out.
                heading = vim.trim((vim.wo[win].winbar:gsub("%%#[^#]*#", ""):gsub("%%%*", ""))),
              }
            end
          end
          return #sides == 2 and sides[1].name:find(":" .. name, 1, true) ~= nil
        end, 50)
        table.sort(sides, function(a, b)
          return a.col < b.col
        end)
        local function joined(field)
          return table.concat(
            vim.tbl_map(function(side)
              return side[field]
            end, sides),
            " | "
          )
        end
        return joined("text"), joined("heading")
      end

      local log = log_of(wc .. "/src/a.c")
      seen.log_tabs = #vim.api.nvim_list_tabpages() - tabs
      seen.first = open_revision(log, 1)
      -- As the rows read: the file name first, its folder after it.
      local rows = {}
      for _, item in ipairs(log.list.items) do
        if item.kind == "file" and item.entry.rev == 1 then
          local parts = {}
          for _, part in ipairs(log.opts.format(item)) do
            parts[#parts + 1] = part[1]
          end
          rows[#rows + 1] = vim.trim(table.concat(parts, "", 2))
        end
      end
      seen.first_rows = table.concat(rows, " | ")
      open_revision(log, 2)
      seen.revision, seen.headings = show(log, 2, "a.c")
      log:close()
      vim.wait(1000, function()
        return #vim.api.nvim_list_tabpages() == tabs
      end, 20)
      seen.tabs_left = #vim.api.nvim_list_tabpages() - tabs

      log = log_of(wc .. "/src")
      seen.changed = open_revision(log, 3)
      seen.deleted = show(log, 3, "b.c")
      seen.added = show(log, 3, "c.c")
      log:close()
      vim.wait(1000, function()
        return #vim.api.nvim_list_tabpages() == tabs
      end, 20)

      vim.cmd.edit(wc .. "/src/a.c")
      vim.wait(8000, function()
        return #vim.fn.sign_getplaced(vim.api.nvim_get_current_buf(), { group = "*" })[1].signs > 0
      end, 100)
      vim.fn.cursor(4, 1)
      vim.fn.confirm = function()
        return 2
      end
      key("<leader>vr")()
      seen.after_no = vim.api.nvim_buf_line_count(0)
      vim.fn.confirm = function()
        return 1
      end
      key("<leader>vr")()
      vim.wait(500)
      seen.after_yes = vim.api.nvim_buf_line_count(0)
      vim.cmd("edit!")
    end)
    vim.fn.confirm = confirm
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.status == "modified:a.c unversioned:0new.txt", "status listed: " .. tostring(seen.status))
    expect(seen.shown == "modified     src/a.c | unversioned  0new.txt", "status shown as: " .. tostring(seen.shown))
    expect(seen.colours == "svnStatus_modified svnStatus_unversioned", "states coloured as: " .. tostring(seen.colours))
    expect(seen.tree_cursor == "src", "the file tree cursor is on " .. tostring(seen.tree_cursor) .. ", not src")
    expect(seen.tree == "modified     a.c", "status of src from the file tree: " .. tostring(seen.tree))
    expect(
      seen.log_tabs == 1 and seen.tabs_left == 0,
      ("the log tab: %s opened, %s left after closing"):format(seen.log_tabs, seen.tabs_left)
    )
    expect(seen.first == "A:a.c A:b.c A:/top.txt(outside)", "r1 of a.c's log lists: " .. tostring(seen.first))
    expect(seen.first_rows == "A a.c | A b.c | A top.txt  /", "r1's rows read: " .. tostring(seen.first_rows))
    expect(
      seen.revision == "int a1;,int a2;,int a3; | int a1;,int A2;,int a3;",
      "r2 side by side: " .. tostring(seen.revision)
    )
    expect(
      (seen.headings or ""):find("^r1  /src/a%.c  %(before r2%) | r2  /src/a%.c  .*  change a2$"),
      "the sides are headed: " .. tostring(seen.headings)
    )
    expect(seen.changed == "D:b.c A:c.c", "r3 of src's log lists: " .. tostring(seen.changed))
    expect(seen.deleted == "int b; | ", "the deleted file side by side: " .. tostring(seen.deleted))
    expect(seen.added == " | int c;", "the added file side by side: " .. tostring(seen.added))
    expect(
      seen.after_no == 4 and seen.after_yes == 3,
      ("hunk undo: %s after no, %s after yes"):format(seen.after_no, seen.after_yes)
    )
  end)
end

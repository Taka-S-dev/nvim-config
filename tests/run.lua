-- Checks that can be counted, for after a plugin update.
--
-- Run with bin/test.cmd, or from the config directory:
--   nvim --headless -n -c "luafile tests/run.lua"
-- It exits with the number of failed checks.
--
-- Every check here stands for something that broke once and could not be seen
-- from the code: a plugin update changed what gitsigns counts as a change, a
-- search hung, index files turned up among the matches. What only shows on a
-- real screen -- where the peek window lands, whether a click feels slow -- is
-- not here, because a headless run cannot see it.
--
-- Nothing on the machine is relied on but the tools: each check builds what it
-- needs under a temporary directory and removes it again. A check whose tool is
-- missing is skipped, not failed.

-- Every process started during the run, by executable, for the last check.
local spawned = {}
do
  local real_spawn = vim.uv.spawn
  vim.uv.spawn = function(exe, ...)
    local name = (tostring(exe):match("[^/\\]+$") or tostring(exe)):lower():gsub("%.exe$", "")
    spawned[name] = (spawned[name] or 0) + 1
    return real_spawn(exe, ...)
  end
end

local results = {}
local temp_dirs = {}

local SKIP = {}

local function skip(reason)
  error(setmetatable({ reason = reason }, SKIP))
end

local function check(name, fn)
  local started = vim.uv.hrtime()
  local ok, err = pcall(fn)
  local result = { name = name, status = "ok" }
  if not ok and getmetatable(err) == SKIP then
    result.status, result.detail = "skip", err.reason
  elseif not ok then
    result.status, result.detail = "FAIL", tostring(err)
  end
  result.seconds = (vim.uv.hrtime() - started) / 1e9
  results[#results + 1] = result
end

local function expect(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function temp_dir()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

-- Where the editor sits between checks. It is not a git repository on purpose:
-- gitsigns watches the HEAD of the repository the cwd is in, and moving in and
-- out of one every second or two sent it into starting git without end.
local neutral_dir = temp_dir()

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function need(...)
  for _, exe in ipairs({ ... }) do
    if vim.fn.executable(exe) == 0 then
      skip(exe .. " is not installed")
    end
  end
end

local function run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait(60000)
  expect(result.code == 0, table.concat(cmd, " ") .. " failed: " .. vim.trim(result.stderr or ""))
  return result.stdout or ""
end

local function key(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  expect(type(map.callback) == "function", lhs .. " is not mapped")
  return map.callback
end

local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function reset_editor()
  for _, win in ipairs(floats()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  vim.api.nvim_set_current_dir(neutral_dir)
end

local function c_project()
  local dir = temp_dir()
  write(dir .. "/lib.c", { "int target_fn(void)", "{", "    return 42;", "}" })
  write(dir .. "/main.c", { "int target_fn(void);", "", "int main(void)", "{", "    return target_fn();", "}" })
  return dir
end

local function run_checks()
  vim.api.nvim_set_current_dir(neutral_dir)
  require("lazy").load({ plugins = { "cscope_maps.nvim", "vim-gutentags", "gitsigns.nvim", "snacks.nvim" } })
  -- The keys ask before writing an index to a directory; the answer is yes.
  vim.fn.confirm = function()
    return 1
  end

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
  check("svn: status, revision diffs and the hunk undo", function()
    need("svn", "svnadmin")
    local svn = require("config.svn")
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
    local global = require("config.gtags_global")
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
    local activity = require("config.activity")
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

  -- The rendering hangs on the markdown parsers and on the plugin's own marks;
  -- when either goes missing the file simply shows as plain text, with no error.
  check("markdown: headings and tables are drawn in place", function()
    local dir = temp_dir()
    write(dir .. "/note.md", { "# Title", "", "| key | does |", "|---|---|", "| a | b |", "", "text" })
    vim.cmd.edit(dir .. "/note.md")
    local namespace
    local drawn = vim.wait(5000, function()
      namespace = namespace or vim.api.nvim_get_namespaces()["render-markdown.nvim"]
      return namespace ~= nil and #vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}) > 0
    end, 100)
    local toggle = vim.fn.maparg("<leader>um", "n") ~= ""
    reset_editor()
    expect(drawn, "nothing was drawn over the markdown source")
    expect(toggle, "<leader>um is not mapped")
  end)

  -- On Windows the built-in gf takes the brackets of `[text](target)` for part
  -- of the file name, and the drawn link hides the target, so gf on a link
  -- found nothing.
  check("markdown: gf follows a link from its text, to a file and to a heading", function()
    -- lua/config/autocmds.lua is read on VeryLazy, which a headless start never
    -- reaches.
    if vim.fn.exists("#markdown_links") == 0 then
      require("config.autocmds")
    end
    local dir = temp_dir()
    write(dir .. "/docs/setup.md", { "# Setup", "", "## 必要なもの (Windows)", "text" })
    write(dir .. "/README.md", {
      "# Title",
      "",
      "一覧を返す([docs/setup.md](docs/setup.md))",
      "[ここ](docs/setup.md#必要なもの-windows) と [下](#レガシー-c-ナビ-gtags--cscope_mapsnvim)",
      "",
      "## レガシー C ナビ (gtags + cscope_maps.nvim)",
    })
    local function follow(line, needle)
      vim.cmd.edit(dir .. "/README.md")
      vim.fn.cursor(line, vim.fn.getline(line):find(needle, 1, true) + 1)
      key("gf")()
      return vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    end
    local from_text = follow(3, "[docs/setup.md]")
    local to_heading_elsewhere = follow(4, "[ここ]")
    local to_heading_here = follow(4, "[下]")
    reset_editor()
    expect(from_text == "setup.md:1", "from the link text: " .. from_text)
    expect(to_heading_elsewhere == "setup.md:3", "file and heading: " .. to_heading_elsewhere)
    expect(to_heading_here == "README.md:6", "heading in the same file: " .. to_heading_here)
  end)

  -- A heading that is renamed leaves the links to it pointing nowhere, and
  -- nothing says so until a reader follows one.
  check("README: every link to a heading or a file leads somewhere", function()
    local config = vim.fn.stdpath("config")
    vim.cmd.edit(config .. "/README.md")
    local broken = {}
    for number, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      -- An example of the syntax inside a code span is not a link.
      for target in line:gsub("`[^`]*`", ""):gmatch("%]%(([^)%s]+)%)") do
        if not target:match("^%a[%w+.-]*:") then
          vim.cmd.edit(config .. "/README.md")
          vim.fn.cursor(number, line:find("](" .. target, 1, true))
          local before = vim.fn.expand("%:p") .. ":" .. vim.fn.line(".")
          key("gf")()
          if vim.fn.expand("%:p") .. ":" .. vim.fn.line(".") == before then
            broken[#broken + 1] = number .. ": " .. target
          end
        end
      end
    end
    reset_editor()
    expect(#broken == 0, "leads nowhere: " .. table.concat(broken, ", "))
  end)

  check("pins: a line is pinned with a note, kept, found again after it moved, removed", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 40 do
      lines[i] = ("int value_%d = %d;"):format(i, i)
    end
    write(dir .. "/GTAGS", {})
    write(dir .. "/src/a.c", lines)
    local root = vim.fs.normalize(dir)
    local pins = require("config.pins")
    local store = pins.store_path(root)
    local input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("length is checked here")
    end
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/src/a.c")
      vim.fn.cursor(20, 1)
      key("<leader>jm")()
      local namespace = vim.api.nvim_get_namespaces().config_pins
      local marks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
      local note = marks[1] and marks[1][4].virt_text[1][1] or ""
      seen.mark = #marks == 1 and marks[1][2] == 19 and note:find("length is checked here", 1, true) ~= nil
      -- A new session reads the file again, and by then the line has moved.
      package.loaded["config.pins"] = nil
      pins = require("config.pins")
      table.insert(lines, 1, "/* three */")
      table.insert(lines, 1, "/* lines */")
      table.insert(lines, 1, "/* added */")
      vim.cmd("silent! %bwipeout!")
      write(dir .. "/src/a.c", lines)
      vim.cmd.edit(dir .. "/src/other.c")
      pins.jump(root, 1)
      seen.landed = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".") .. ":" .. vim.trim(vim.fn.getline("."))
      local stored = vim.json.decode(table.concat(vim.fn.readfile(store)))
      seen.stored = stored.pins[1].file .. ":" .. stored.pins[1].line .. ":" .. stored.pins[1].memo
      pins.remove(root, 1)
      seen.left = #vim.json.decode(table.concat(vim.fn.readfile(store))).pins
    end)
    vim.ui.input = input
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.mark, "the pinned line shows no mark with its note")
    expect(seen.landed == "a.c:23:int value_20 = 20;", "landed on " .. tostring(seen.landed))
    expect(seen.stored == "src/a.c:23:length is checked here", "stored as " .. tostring(seen.stored))
    expect(seen.left == 0, "the pin was not removed")
  end)

  -- The ways a note was lost or shown in the wrong place: a mark drawn at the
  -- old line number after the file changed outside, the pin key making a
  -- second pin on a line that had one, and a slip of dd. One pin goes without
  -- a question and comes back with u; several at once ask first.
  check("pins: marks follow the line, the key acts on an existing pin, removal can be undone", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 30 do
      lines[i] = ("int value_%d = %d;"):format(i, i)
    end
    write(dir .. "/GTAGS", {})
    write(dir .. "/a.c", lines)
    local root = vim.fs.normalize(dir)
    local pins = require("config.pins")
    local store = pins.store_path(root)
    local input, select, confirm = vim.ui.input, vim.ui.select, vim.fn.confirm
    local seen = {}
    local function stored()
      return vim.json.decode(table.concat(vim.fn.readfile(store))).pins
    end
    local function marked_lines()
      local rows = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().config_pins, 0, -1, {})) do
        rows[#rows + 1] = mark[2] + 1
      end
      return table.concat(rows, ",")
    end
    local ok, err = pcall(function()
      vim.ui.input = function(_, on_confirm)
        on_confirm("first note")
      end
      vim.cmd.edit(dir .. "/a.c")
      vim.fn.cursor(10, 1)
      key("<leader>jm")()

      -- The file changes outside the editor: five lines go in above the pin.
      vim.cmd("silent! %bwipeout!")
      for _ = 1, 5 do
        table.insert(lines, 1, "/* added */")
      end
      write(dir .. "/a.c", lines)
      vim.cmd.edit(dir .. "/a.c")
      seen.mark_after_change = marked_lines()
      seen.line_after_change = stored()[1].line

      -- The key on the pinned line offers the pin, and makes no second one.
      local offered
      vim.ui.select = function(choices, _, on_choice)
        offered = table.concat(choices, "|")
        on_choice("Edit the note")
      end
      vim.ui.input = function(options, on_confirm)
        seen.default = options.default
        on_confirm("second note")
      end
      vim.fn.cursor(15, 1)
      key("<leader>jm")()
      seen.offered = offered
      seen.after_edit = #stored() .. ":" .. stored()[1].memo

      -- Taken off from its line: no question, and u brings it back.
      local asked = 0
      vim.fn.confirm = function()
        asked = asked + 1
        return 2
      end
      vim.ui.select = function(_, _, on_choice)
        on_choice("Remove the pin")
      end
      key("<leader>jm")()
      seen.removed = #stored()
      seen.mark_after_removal = marked_lines()
      seen.asked_for_one = asked
      pins.undo(root)
      seen.undone = #stored() .. ":" .. stored()[1].memo .. ":" .. marked_lines()
      pins.undo(root, true)
      seen.redone = #stored()
      pins.undo(root)

      -- Several at once: a question, "keep" keeps them, and one u restores all.
      vim.ui.select = select
      vim.ui.input = function(_, on_confirm)
        on_confirm("another")
      end
      vim.fn.cursor(20, 1)
      key("<leader>jm")()
      local ids = vim.tbl_map(function(pin)
        return pin.id
      end, stored())
      pins.remove_many(root, ids)
      seen.kept = #stored() .. " after " .. asked .. " question"
      vim.fn.confirm = function()
        return 1
      end
      pins.remove_many(root, ids)
      seen.all_gone = #stored()
      pins.undo(root)
      seen.all_back = #stored()
    end)
    vim.ui.input, vim.ui.select, vim.fn.confirm = input, select, confirm
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.mark_after_change == "15", "the mark is drawn on line " .. tostring(seen.mark_after_change))
    expect(seen.line_after_change == 15, "the stored line is " .. tostring(seen.line_after_change))
    expect(
      seen.offered == "Edit the note|Remove the pin",
      "on a pinned line the key offered: " .. tostring(seen.offered)
    )
    expect(seen.default == "first note", "the note to edit was not filled in")
    expect(seen.after_edit == "1:second note", "after editing from the line: " .. tostring(seen.after_edit))
    expect(seen.removed == 0 and seen.mark_after_removal == "", "removing from the line left something behind")
    expect(seen.asked_for_one == 0, "removing one pin asked a question")
    expect(seen.undone == "1:second note:15", "after undo: " .. tostring(seen.undone))
    expect(seen.redone == 0, "redo did not remove it again")
    expect(seen.kept == "2 after 1 question", "removing several, answered keep: " .. tostring(seen.kept))
    expect(seen.all_gone == 0 and seen.all_back == 2, "several removed, then one undo: " .. tostring(seen.all_back))
  end)

  -- A pin stores its path relative to its project. With no GTAGS or .git above
  -- the file and the cwd somewhere else, that path was cut against the cwd and
  -- pointed at nothing.
  check("pins: a file outside the cwd, in no project, is pinned where it is", function()
    local elsewhere = temp_dir()
    write(elsewhere .. "/sub/far.c", { "int x;", "int y;" })
    local pins = require("config.pins")
    local store = pins.store_path(vim.fs.normalize(elsewhere .. "/sub"))
    local input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("outside")
    end
    local stored, landed
    local ok, err = pcall(function()
      vim.cmd.edit(elsewhere .. "/sub/far.c")
      vim.fn.cursor(2, 1)
      key("<leader>jm")()
      stored = vim.json.decode(table.concat(vim.fn.readfile(store)))
      vim.cmd.edit(elsewhere .. "/sub/other.c")
      pins.jump(stored.root, 1)
      landed = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    end)
    vim.ui.input = input
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(stored.pins[1].file == "far.c", "stored as " .. tostring(stored.pins[1].file))
    expect(landed == "far.c:2", "landed on " .. tostring(landed))
  end)

  check("pins: the panel nests, reorders, filters and removes without losing a note", function()
    local dir = temp_dir()
    write(dir .. "/GTAGS", {})
    write(dir .. "/a.c", { "int a;", "int b;", "int c;", "int d;" })
    local root = vim.fs.normalize(dir)
    local pins = require("config.pins")
    local store = pins.store_path(root)
    -- A file from before pins had ids or parents.
    local legacy = { file = "a.c", line = 1, text = "int a;", symbol = "", memo = "A" }
    write(store, { vim.json.encode({ root = root, pins = { legacy } }) })
    local input = vim.ui.input
    local notify = vim.notify
    local warned = 0
    local seen = {}
    local picker
    local function tree()
      return table.concat(pins.outline(root), " ")
    end
    local function rows()
      -- A change to the filter box reaches the finder a moment later.
      vim.wait(300)
      vim.wait(3000, function()
        return not picker:is_active()
      end, 20)
      vim.wait(100)
      return vim.tbl_map(function(item)
        local text = ""
        for _, chunk in ipairs(picker.opts.format(item, picker)) do
          -- The place is virtual text at the right edge, not part of the line.
          local part = chunk[1]
          if chunk.virt_text then
            seen.right_edge = seen.right_edge or chunk.virt_text_pos == "right_align"
            part = " @" .. chunk.virt_text[2][1]
          end
          text = text .. part
          -- "Normal" brings the background of the editing windows with it: a
          -- box on the sidebar, and a hole in the line under the cursor.
          seen.boxed = seen.boxed or chunk[2] == "Normal"
        end
        return text
      end, picker:items())
    end
    local leaves_the_pin = { pin_remove = true, pin_undo = true, confirm = true, select_and_next = true }
    local function on_row(note, action)
      for index, item in ipairs(picker:items()) do
        if item.pin.memo == note then
          picker.list:view(index)
        end
      end
      -- Every move of the list cursor while the change is drawn: a visit to the
      -- first row on the way shows as a flash at the top of the panel.
      local set_cursor, visited = vim.api.nvim_win_set_cursor, {}
      vim.api.nvim_win_set_cursor = function(win, position)
        if win == picker.list.win.win then
          visited[#visited + 1] = position[1]
        end
        return set_cursor(win, position)
      end
      picker:action(action)
      rows()
      vim.api.nvim_win_set_cursor = set_cursor
      local final = vim.api.nvim_win_get_cursor(picker.list.win.win)[1]
      if final ~= 1 and vim.tbl_contains(visited, 1) and not leaves_the_pin[action] then
        seen.flashed = seen.flashed or (action .. " on " .. note)
      end
      -- The list is filled again after every change, which takes the cursor to
      -- the first row unless it is put back on the pin that was acted on.
      local current = picker:current()
      if not leaves_the_pin[action] and (not current or current.pin.memo ~= note) then
        seen.cursor_lost = seen.cursor_lost or (action .. " on " .. note)
      end
    end
    -- As typing does it: the text goes into the filter box and the box is told
    -- that it changed.
    local function type_filter(text)
      local buf = picker.input.win.buf
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      rows()
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      for line, note in ipairs({ false, "B", "C", "D" }) do
        if note then
          vim.ui.input = function(_, on_confirm)
            on_confirm(note)
          end
          vim.fn.cursor(line, 1)
          key("<leader>jm")()
        end
      end
      seen.added = tree()
      -- With the file tree open as well: two snacks sidebars on one side are
      -- each set to half the height, which left the lower half of the screen
      -- to an empty command line.
      Snacks.explorer({ cwd = dir })
      vim.wait(800)
      vim.cmd("wincmd p")
      local command_line = vim.o.cmdheight
      key("<leader>jo")()
      vim.wait(800)
      seen.screen_kept = vim.o.cmdheight == command_line
      for _, tree_picker in ipairs(Snacks.picker.get({ source = "explorer" })) do
        tree_picker:close()
      end
      picker = Snacks.picker.get({ source = "pins" })[1]
      expect(picker ~= nil, "the panel did not open")
      rows()
      seen.keys = vim.fn.maparg("K", "n", false, true).desc ~= nil
      on_row("C", "pin_in")
      on_row("D", "pin_in")
      on_row("D", "pin_out")
      on_row("D", "pin_in")
      seen.nested = tree()
      seen.guides = "\n" .. table.concat(rows(), "\n")
      on_row("B", "pin_fold")
      seen.closed = #rows()
      seen.kept_closed = vim.json.decode(table.concat(vim.fn.readfile(store))).pins[2].collapsed
      -- A filter finds a pin under a closed one and shows it under its parent,
      -- and nothing can be arranged meanwhile.
      vim.notify = function()
        warned = warned + 1
      end
      type_filter("D")
      seen.filtered = table.concat(rows(), "|")
      local before = tree()
      on_row("D", "pin_out")
      seen.frozen = tree() == before
      type_filter("")
      vim.notify = notify
      on_row("B", "pin_open")
      seen.opened = #rows()
      on_row("B", "pin_up")
      seen.moved = tree()
      on_row("B", "pin_remove")
      seen.removed = tree()
      -- Marked with Tab and removed together, then brought back with one u.
      on_row("C", "select_and_next")
      on_row("D", "select_and_next")
      on_row("A", "pin_remove")
      seen.marked_removed = tree()
      on_row("A", "pin_undo")
      seen.marked_back = tree()
      on_row("D", "confirm")
      seen.jumped = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      seen.still_open = not picker.closed
    end)
    vim.ui.input = input
    vim.notify = notify
    if picker and not picker.closed then
      picker:close()
    end
    vim.fn.delete(store)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.added == "0:A 0:B 0:C 0:D", "a new pin goes to the end, at the top level: " .. tostring(seen.added))
    expect(seen.screen_kept, "opening the panel beside the file tree grew the command line")
    expect(seen.right_edge, "the place is not at the right edge of the row")
    expect(not seen.boxed, "a row is drawn with the background of the editing windows")
    expect(not seen.flashed, "the cursor went by the first row after " .. tostring(seen.flashed))
    expect(not seen.cursor_lost, "the cursor left the pin after " .. tostring(seen.cursor_lost))
    expect(seen.nested == "0:A 0:B 1:C 1:D", "nesting under the pin above: " .. tostring(seen.nested))
    local drawn = seen.guides or ""
    expect(
      drawn:find("\n[^ ╴]+ B @a.c:2")
        and drawn:find("\n├╴[^ ]+ C @a.c:3")
        and drawn:find("\n└╴[^ ]+ D @a.c:4"),
      "guide lines: " .. drawn
    )
    expect(
      seen.closed == 2 and seen.opened == 4,
      ("closing B leaves %s rows, opening it %s"):format(seen.closed, seen.opened)
    )
    expect(seen.kept_closed == true, "what is closed is not stored")
    expect(
      (seen.filtered or ""):find("^[^ ╴]+ B @.*|└╴[^ ]+ D @") and not seen.filtered:find(" [AC] @"),
      "a filter keeps the match under its parent and drops the rest: " .. tostring(seen.filtered)
    )
    expect(seen.frozen and warned == 1, "arranging went on while a filter was typed")
    expect(seen.moved == "0:B 1:C 1:D 0:A", "a pin moves with the pins under it: " .. tostring(seen.moved))
    expect(seen.removed == "0:C 0:D 0:A", "removing a parent keeps its children: " .. tostring(seen.removed))
    expect(seen.marked_removed == "0:A", "dd with two pins marked left: " .. tostring(seen.marked_removed))
    expect(seen.marked_back == "0:C 0:D 0:A", "u after that: " .. tostring(seen.marked_back))
    expect(seen.jumped == "a.c:4", "Enter in the panel: " .. tostring(seen.jumped))
    expect(seen.still_open, "the panel closed on a jump")
  end)

  -- Two files in diff mode, each with a strip of where they differ: a changed
  -- line, a line only on the right and one only on the left sit on the same
  -- rows of both strips, the part in view is lit and moves with the view, a
  -- click on a change lands on it, and the strips go with the diff.
  check("diff map: a strip shows where two files differ, and a click goes there", function()
    local map = require("config.diff_map")
    local left_lines, right_lines = {}, {}
    for line = 1, 200 do
      left_lines[line] = "line " .. line
      right_lines[line] = "line " .. line
    end
    right_lines[20] = "line 20 changed"
    table.insert(right_lines, 100, "only on the right")
    table.insert(left_lines, 150, "only on the left")
    local seen = {}
    local mousepos = vim.fn.getmousepos
    local ok, err = pcall(function()
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, left_lines)
      vim.cmd("diffthis")
      local left = vim.api.nvim_get_current_win()
      vim.cmd("rightbelow vnew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, right_lines)
      vim.cmd("diffthis")
      local right = vim.api.nvim_get_current_win()
      vim.cmd("normal! gg")
      local function states(strip)
        return table.concat(vim.tbl_map(function(row)
          return row:sub(2, 2)
        end, strip or {}))
      end
      -- Nothing folded, so the strip and the screen agree on where lines are.
      seen.folded = vim.fn.foldclosed(30) ~= -1 or vim.fn.foldclosed(200) ~= -1
      local left_strip, right_strip = map.strip(left), map.strip(right)
      seen.left, seen.right = states(left_strip), states(right_strip)
      seen.view_top = right_strip and right_strip[1]:sub(1, 1)
      vim.cmd("normal! G")
      seen.view_moved = (map.strip(right) or {})[1]
      vim.cmd("normal! gg")
      vim.cmd("wincmd h")
      local row = (seen.right:find("~", 1, true) or 1) - 1
      vim.fn.getmousepos = function()
        return { winid = right, wincol = vim.api.nvim_win_get_width(right) - 1, winrow = row + 1 }
      end
      -- Through the key itself: the mapping runs where windows may not be
      -- changed, which calling the function directly never met.
      local errors = vim.v.errmsg
      vim.v.errmsg = ""
      press("<LeftMouse>")
      vim.wait(1000, function()
        return vim.api.nvim_get_current_win() == right
      end, 20)
      seen.click_error = vim.v.errmsg
      vim.v.errmsg = errors
      seen.landed = vim.api.nvim_get_current_win() == right and vim.fn.line(".")
      vim.fn.getmousepos = function()
        return { winid = right, wincol = 1, winrow = row + 1 }
      end
      seen.text_click = map.target()
      -- The clear column at the edge, beside the border that is dragged.
      vim.fn.getmousepos = function()
        return { winid = right, wincol = vim.api.nvim_win_get_width(right), winrow = row + 1 }
      end
      seen.edge_click = map.target()
      vim.fn.getmousepos = mousepos
      vim.cmd("diffoff!")
      vim.wait(200)
      seen.after = map.strip(left) == nil and map.strip(right) == nil and #floats() == 0
    end)
    vim.fn.getmousepos = mousepos
    reset_editor()
    expect(ok, tostring(err))
    local mirrored = seen.left:gsub("[+-]", { ["+"] = "-", ["-"] = "+" })
    expect(
      seen.left:find("~", 1, true) and seen.left:find("+", 1, true) and seen.left:find("-", 1, true),
      "the left strip shows " .. seen.left
    )
    expect(mirrored == seen.right, ("the strips do not line up: %s | %s"):format(seen.left, seen.right))
    expect(not seen.folded, "the diff folds the lines that did not change")
    expect(seen.right:sub(1, 1) == ",", "the part in view is not drawn as a band: " .. seen.right)
    expect(
      seen.view_top == "v" and seen.view_moved == "..",
      "the part in view: at the top "
        .. tostring(seen.view_top)
        .. ", after G the first row "
        .. tostring(seen.view_moved)
    )
    expect(seen.click_error == "", "the click raised: " .. tostring(seen.click_error))
    expect(seen.landed == 20, "a click on the change landed on " .. tostring(seen.landed))
    expect(seen.text_click == nil, "a click in the text was taken by the strip")
    expect(seen.edge_click == nil, "a click at the window's edge, by the border, was taken by the strip")
    expect(seen.after, "the strips outlived the diff")
  end)

  -- The pane below a diff holds the block of changed lines the cursor is in,
  -- the left side in its top half and the right side in its bottom half,
  -- wrapped so that a change at the end of a long line is in sight, with the
  -- part of each line that differs from the one facing it marked. A line only
  -- one side has faces a blank line, so the halves stay row for row and scroll
  -- together; the cursor's line alone is shown where nothing changed; the pane
  -- keeps its place while the block stays the same, and goes with the diff.
  check("diff pane: the block under the cursor from both sides, the difference marked", function()
    local pane = require("config.diff_pane")
    local long = "static int parse_record(struct stream *s, size_t limit, int flags, const char *name, void *userdata)"
    -- Two changes in one line: each is marked, and what lies between is not.
    local changed = (long:gsub("int flags", "int mode"):gsub("void %*userdata", "const void *context"))
    local left_lines = { "line 1", long, "tall = 55;", "line 4", "gone 1", "gone 2", "line 5", "line 6" }
    local right_lines = { "line 1", changed, "tall = 5;", "line 4", "line 5", "right only", "line 6" }
    local seen = {}
    local function read(line)
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      pane.refresh()
      local shown = pane.shown()
      return shown and (shown[1] .. " || " .. shown[2])
    end
    local ok, err = pcall(function()
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, left_lines)
      vim.cmd("diffthis")
      vim.cmd("rightbelow vnew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, right_lines)
      vim.cmd("diffthis")
      seen.block = read(3)
      local halves = pane.shown().windows
      seen.wrap = vim.wo[halves[1]].wrap and vim.wo[halves[2]].wrap
      -- The words that differ drawn over the changed line's colour. A line
      -- highlight is laid over everything on its line whatever its priority,
      -- so the line's colour is a range through its end, below the words.
      -- (Drawn through an attached UI, the words showed only this way.)
      local top = vim.api.nvim_win_get_buf(halves[1])
      local word, line, line_hl
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(top, -1, 0, -1, { details = true })) do
        if mark[4].hl_group == "DiffText" then
          word = mark[4].priority
        elseif mark[4].hl_group == "DiffChange" and mark[4].hl_eol then
          line = mark[4].priority
        end
        line_hl = line_hl or mark[4].line_hl_group ~= nil
      end
      seen.over = word and line and word > line and not line_hl
      -- The top half scrolled, as the wheel does: the bottom half follows, and
      -- a refresh on the same block leaves both where they are.
      vim.api.nvim_win_call(halves[1], function()
        vim.fn.winrestview({ topline = 2, lnum = 2 })
      end)
      pane.follow(halves[1])
      pane.refresh()
      seen.kept = vim.fn.line("w0", halves[1]) .. "/" .. vim.fn.line("w0", halves[2])
      -- The half under the mouse leads, and the other is only moved: a scroll
      -- reported by the bottom half while the wheel turns the top one moves
      -- the bottom half to the top one, not the top half back. Following
      -- whichever half reported a scroll sent the halves up and down after
      -- the wheel had stopped.
      vim.api.nvim_win_call(halves[1], function()
        vim.fn.winrestview({ topline = 1, lnum = 1 })
      end)
      local mousepos = vim.fn.getmousepos
      vim.fn.getmousepos = function()
        return { winid = halves[1], winrow = 1, wincol = 1 }
      end
      pcall(pane.scrolled, { halves[2] })
      vim.fn.getmousepos = mousepos
      seen.answer = vim.fn.line("w0", halves[1]) .. "/" .. vim.fn.line("w0", halves[2])
      -- Whole lines, and no lines kept clear around the cursor, in halves a few
      -- rows high: either pushed the view against the wheel.
      seen.scrolling = tostring(vim.wo[halves[1]].smoothscroll) .. "/" .. vim.wo[halves[1]].scrolloff
      -- The halves keep their height whatever block they hold. The pane made
      -- taller by hand, as by dragging the border above it, grows both halves
      -- alike, and is as tall when it opens next.
      local heights = function()
        local shown = pane.shown()
        return vim.api.nvim_win_get_height(shown.windows[1]) .. "/" .. vim.api.nvim_win_get_height(shown.windows[2])
      end
      local before = heights()
      seen.before = before
      seen.one_side = read(6)
      seen.steady = heights() == before
      local halves_now = pane.shown().windows
      vim.api.nvim_win_set_height(halves_now[1], vim.api.nvim_win_get_height(halves_now[1]) + 4)
      pane.resized({ halves_now[1] })
      seen.grown = heights()
      vim.cmd("diffoff!")
      pane.refresh()
      vim.cmd("windo diffthis")
      vim.cmd("wincmd l")
      read(6)
      seen.chosen = heights()
      -- On the line below lines only the left has, where ]c stops on the right.
      seen.deleted = read(5)
      seen.unchanged = read(1)
      vim.cmd("diffoff!")
      seen.after = read(1)
    end)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.wrap, "the pane does not wrap")
    expect(vim.o.diffopt:find("inline:word", 1, true), "the diff marks changes by character: " .. vim.o.diffopt)
    expect(seen.over, "the words that differ are hidden under the changed line's colour")
    expect(
      seen.block
        == long .. " [flags,userdata] / tall = 55; [55] || " .. changed .. " [mode,const,context] / tall = 5; [5]",
      "the block reads: " .. tostring(seen.block)
    )
    expect(seen.kept == "2/2", "top lines of the halves after scrolling the top one: " .. tostring(seen.kept))
    expect(seen.answer == "1/1", "after the bottom half reported a scroll, the halves are at " .. tostring(seen.answer))
    expect(seen.scrolling == "false/0", "the halves scroll with smoothscroll/scrolloff " .. tostring(seen.scrolling))
    expect(seen.one_side == "(none) || right only", "a line on one side reads: " .. tostring(seen.one_side))
    expect(seen.steady, "the pane changed its height with the block")
    local top, bottom = (seen.grown or ""):match("^(%d+)/(%d+)$")
    expect(
      top and top == bottom and seen.grown ~= seen.before,
      "the pane made taller by hand reads " .. tostring(seen.grown)
    )
    expect(
      seen.chosen == seen.grown,
      "a pane opened again is " .. tostring(seen.chosen) .. " high, not " .. tostring(seen.grown)
    )
    expect(
      seen.deleted == "gone 1 / gone 2 || (none) / (none)",
      "lines only on the left read: " .. tostring(seen.deleted)
    )
    expect(seen.unchanged == "line 1 || line 1", "an unchanged line reads: " .. tostring(seen.unchanged))
    expect(seen.after == nil, "the pane outlived the diff")
  end)

  -- The pane takes its rows from the diff. A change the cursor was on near
  -- the foot of the view stays in sight, and entering the window leaves the
  -- cursor on it rather than pulling it up to what is still shown.
  check("diff pane: opening it keeps the change under the cursor in view", function()
    local pane = require("config.diff_pane")
    local left_lines = {}
    for line = 1, 120 do
      left_lines[line] = "line " .. line
    end
    local right_lines = vim.deepcopy(left_lines)
    for line = 56, 60 do
      right_lines[line] = "changed " .. line
    end
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, left_lines)
      vim.cmd("diffthis")
      vim.cmd("rightbelow vnew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, right_lines)
      vim.cmd("diffthis")
      local right = vim.api.nvim_get_current_win()
      vim.cmd("normal! gg]c")
      vim.cmd("botright 3new")
      pane.refresh()
      vim.cmd("redraw")
      vim.api.nvim_set_current_win(right)
      seen.cursor = vim.fn.line(".")
      seen.in_view = vim.fn.line(".") >= vim.fn.line("w0") and vim.fn.line(".") <= vim.fn.line("w$")
    end)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.cursor == 56 and seen.in_view, ("the cursor is on %s, in view: %s"):format(seen.cursor, seen.in_view))
  end)

  -- q ends a comparison from any of its windows, however it was opened: a file
  -- against a side that is no file (a scratch copy, git's revision or index)
  -- loses that side and leaves diff mode, the svn log's tab closes; outside a
  -- comparison q still records a macro.
  check("diff quit: q ends a comparison, and records a macro elsewhere", function()
    local quit = require("config.diff_quit")
    local function typed(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    end
    local seen = {}
    local ok, err = pcall(function()
      local file = temp_dir() .. "/a.c"
      write(file, { "int a;", "int b;" })
      vim.cmd.edit(file)
      vim.cmd("diffthis")
      vim.cmd("leftabove vnew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int a;", "int B;" })
      vim.cmd("diffthis")
      vim.cmd("wincmd l")
      seen.here = quit.here()
      typed("q")
      vim.wait(500, function()
        return #vim.api.nvim_tabpage_list_wins(0) == 1
      end, 20)
      seen.file = #vim.api.nvim_tabpage_list_wins(0) .. " " .. tostring(vim.wo.diff) .. " " .. vim.fn.expand("%:t")

      -- git's sides, as gitsigns opens them: a revision is nowrite and the
      -- index acwrite. Both close, except an index with edits not written
      -- back, which stays out of diff mode.
      seen.git = {}
      for _, side in ipairs({ "nowrite", "acwrite", "acwrite edited" }) do
        vim.cmd("diffthis")
        vim.cmd("leftabove vnew")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int a;", "int B;" })
        vim.bo.buftype = side:match("^%a+")
        vim.bo.modified = side:find("edited") ~= nil
        vim.cmd("diffthis")
        vim.cmd("wincmd l")
        typed("q")
        vim.wait(500, function()
          return not vim.wo.diff
        end, 20)
        local wins = vim.api.nvim_tabpage_list_wins(0)
        seen.git[#seen.git + 1] = #wins .. " " .. tostring(vim.wo[wins[1]].diff)
        vim.cmd("only!")
      end
      seen.git = table.concat(seen.git, ", ")

      local tabs = #vim.api.nvim_list_tabpages()
      vim.cmd("tabnew")
      vim.t.svn_log = true
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
      vim.cmd("diffthis")
      vim.cmd("rightbelow vnew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "X" })
      vim.cmd("diffthis")
      typed("q")
      vim.wait(500, function()
        return #vim.api.nvim_list_tabpages() == tabs
      end, 20)
      seen.tab_left = #vim.api.nvim_list_tabpages() - tabs

      -- Two files of their own, as nvim -d opens them: both stay, out of
      -- diff mode.
      local other = temp_dir() .. "/b.c"
      write(other, { "int a;", "int c;" })
      vim.cmd.edit(file)
      vim.cmd("diffthis")
      vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(other))
      vim.cmd("diffthis")
      typed("q")
      vim.wait(500, function()
        return not vim.wo.diff
      end, 20)
      local modes = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        modes[#modes + 1] = tostring(vim.wo[win].diff)
      end
      seen.files = #modes .. " " .. table.concat(modes, ",")
      vim.cmd("only")

      vim.cmd("enew")
      vim.fn.setreg("a", "")
      typed("qa")
      seen.recording = vim.fn.reg_recording()
      typed("ihello<Esc>")
      typed("q")
      seen.macro = vim.fn.getreg("a")
    end)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.here, "a window in diff mode is not taken for part of a comparison")
    expect(seen.file == "1 false a.c", "after q beside a file: windows, diff, buffer = " .. tostring(seen.file))
    expect(
      seen.git == "1 false, 1 false, 2 false",
      "after q beside git's revision, index, edited index: windows, diff = " .. tostring(seen.git)
    )
    expect(seen.tab_left == 0, "the svn log's tab is still open after q")
    expect(seen.files == "2 false,false", "two files after q: windows, diff = " .. tostring(seen.files))
    expect(seen.recording == "a", "qa outside a comparison did not start recording")
    expect(seen.macro == "ihello\27", "q no longer records a macro outside a comparison: " .. vim.inspect(seen.macro))
  end)

  -- One side of a diff scrolled without a command, as the wheel does over the
  -- side the cursor is not in, brings the other side along, lined up through
  -- the lines only one side has. The event that sets it off does not come in
  -- a headless run, which has no screen, so the part it calls is run here.
  check("diff scroll: a side scrolled by the wheel brings the other along", function()
    local follow = require("config.diff_scroll").follow
    local left_lines = {}
    for line = 1, 400 do
      left_lines[line] = "line " .. line
    end
    local right_lines = vim.deepcopy(left_lines)
    right_lines[50] = "line 50 changed"
    for count = 1, 5 do
      table.insert(right_lines, 100, "only on the right " .. count)
    end
    local seen = {}
    -- Folded as nvim folds a diff by default: this config unfolds diffs, but
    -- a fold is where lining up went wrong, so the check keeps one.
    local diffopt = vim.o.diffopt
    vim.opt.diffopt:remove("context:1000000")
    local ok, err = pcall(function()
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, left_lines)
      vim.cmd("diffthis")
      local left = vim.api.nvim_get_current_win()
      vim.cmd("rightbelow vnew")
      vim.bo.buftype = "nofile"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, right_lines)
      vim.cmd("diffthis")
      local right = vim.api.nvim_get_current_win()
      vim.cmd("botright 5new")
      -- Scrolled by a command with the other side let go of for it, scroll
      -- and cursor, which leaves the other side behind as the wheel does;
      -- then followed.
      local function scroll(win, keys)
        local other = win == left and right or left
        vim.wo[other].scrollbind, vim.wo[other].cursorbind = false, false
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(keys, true, false, true))
        end)
        vim.wo[other].scrollbind, vim.wo[other].cursorbind = true, true
        follow(win)
        return vim.fn.line("w0", left) .. "/" .. vim.fn.line("w0", right)
      end
      -- The tops expected are where scrolling the bound pair in the current
      -- window puts them, the way nvim lines them up itself.
      -- Unchanged lines folded, as a diff shows them: the fold around the
      -- change is where lining up by offset went wrong.
      seen.folded = scroll(right, "3<C-e>") .. " " .. scroll(right, "3<C-e>")
      for _, win in ipairs({ left, right }) do
        vim.wo[win].foldenable = false
      end
      seen.below = scroll(right, "200<C-e>5j")
      seen.cursor = vim.api.nvim_win_get_cursor(left)[1] .. "/" .. vim.api.nvim_win_get_cursor(right)[1]
      seen.above = scroll(left, "150<C-y>")
      seen.top = scroll(right, "gg")
      seen.wired = #vim.api.nvim_get_autocmds({ group = "config_diff_scroll", event = "WinScrolled" })
      -- Smooth scrolling would leave the other side a step behind through a
      -- jump: it is off in the diff, on in the window below it.
      local animates = Snacks.config.get("scroll", {}).filter
      seen.animates = tostring(animates(vim.api.nvim_win_get_buf(right)))
        .. "/"
        .. tostring(animates(vim.api.nvim_get_current_buf()))
    end)
    vim.o.diffopt = diffopt
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.folded == "46/46 49/49", "folded, left/right tops after two scrolls: " .. tostring(seen.folded))
    expect(seen.below == "244/249", "right scrolled past the 5 lines, left/right tops: " .. tostring(seen.below))
    expect(seen.cursor == "253/258", "the cursors are not on the same row, left/right: " .. tostring(seen.cursor))
    expect(seen.above == "99/99", "left scrolled back, left/right tops: " .. tostring(seen.above))
    expect(seen.top == "1/1", "right scrolled to the top, left/right tops: " .. tostring(seen.top))
    expect(seen.wired == 1, "follow is not run when a window scrolls")
    expect(seen.animates == "false/true", "smooth scrolling in the diff / outside it: " .. tostring(seen.animates))
  end)

  -- An if without braces whose body is another if: the inner one is a field
  -- of the outer in treesitter's view, and snacks passed it over for the
  -- outer, so the scope line lit up the wrong block.
  check("scope: a nested if under a brace-less if gets its own scope line", function()
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "int f(int a, int b)",
      "{",
      "    if (a)",
      "        if (b) {",
      "            return 1;",
      "        }",
      "    return 0;",
      "}",
    })
    vim.cmd.edit(dir .. "/a.c")
    vim.treesitter.get_parser(0):parse(true)
    local got = {}
    for _, line in ipairs({ 4, 5 }) do
      Snacks.scope.get(function(scope)
        got[#got + 1] = ("%d:%s-%s@%s"):format(
          line,
          scope and scope.from or "?",
          scope and scope.to or "?",
          scope and scope.indent or "?"
        )
      end, { buf = 0, pos = { line, 8 } })
      vim.wait(1000, function()
        return #got == #got
      end, 50)
    end
    vim.wait(500)
    reset_editor()
    expect(table.concat(got, " ") == "4:4-6@8 5:4-6@8", "scopes: " .. table.concat(got, " "))
  end)

  check("scope pin: the line stays on its block while the cursor leaves", function()
    require("config.scope_pin")
    local dir = temp_dir()
    local lines = { "int f(void)", "{", "    while (1) {", "        a();", "        b();", "    }" }
    for i = 1, 100 do
      lines[#lines + 1] = "    c();"
    end
    lines[#lines + 1] = "}"
    write(dir .. "/a.c", lines)
    vim.cmd.edit(dir .. "/a.c")
    vim.treesitter.get_parser(0):parse(true)
    vim.fn.cursor(4, 9)
    key("<leader>jl")()
    vim.wait(1500, function()
      return vim.b.scope_pin ~= nil
    end, 50)
    local pinned = vim.b.scope_pin
    vim.fn.cursor(90, 1)
    vim.cmd("normal! zt")
    local ns = vim.api.nvim_get_namespaces().config_scope_pin
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    local rows = {}
    for _, mark in ipairs(marks) do
      rows[#rows + 1] = mark[2] + 1
    end
    key("<leader>jl")()
    local after = #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    reset_editor()
    expect(pinned and pinned.from == 3 and pinned.to == 6, "pinned block: " .. vim.inspect(pinned))
    expect(table.concat(rows, ",") == "4,5", "lines drawn after moving away: " .. table.concat(rows, ","))
    expect(after == 0, "pressing the key again did not take the line away")
  end)

  -- Which capitalised name is a macro and which an enum value, from the file's
  -- own definitions and from the tags file; a lowercase name only from the
  -- file, and a name found nowhere left to the grammar.
  check("c macros: macros and enum values are told apart where they are used", function()
    local names = require("config.c_macros")
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
    local names = require("config.c_macros")
    local global = require("config.gtags_global")
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

  -- The call tree, both ways, on a project made to hold what broke it on real
  -- code: a prototype that is no call, a call made in a macro's body, a
  -- function that calls itself, a folder with a space in its name, a type on a
  -- line of its own before the name, a function #ifdef leaves the grammar
  -- unable to read, and more names to look up at once than global takes in
  -- one pattern.
  check("call tree: callers and callees from GTAGS, opened a branch at a time", function()
    need("gtags", "global")
    local tree = require("config.call_tree")
    local dir = temp_dir()
    write(dir .. "/a.c", {
      "static int leaf(int x) { return x + 1; }",
      "int mid(int x) { return leaf(x) * 2; }",
      'int top(void) { return mid(1) + mid(2) + leaf(3) + printf("") + split_type(); }',
      "int rec(int n) { return n ? rec(n - 1) : 0; }",
      "int",
      "split_type(void)",
      "{",
      "    return leaf(4);",
      "}",
    })
    write(dir .. "/sub dir/b.c", {
      "int mid(int x);",
      "int other(void) { return mid(5); }",
      "#define CALL_MID(x) mid(x)",
      "int via_macro(void) { return CALL_MID(1); }",
    })
    -- A file of its own: what comes before a part the grammar cannot read
    -- changes how it reads it.
    write(dir .. "/sub dir/d.c", {
      "int mid(int x);",
      "int broken(int n)",
      "{",
      "#ifdef A",
      "    if (n) {",
      "#else",
      "    if (!n) {",
      "#endif",
      "        return mid(6);",
      "    }",
      -- Taken for a function of its own in the part the grammar could not read.
      "    for_each_item(n) {",
      "        n = mid(7);",
      "    }",
      "    return 0;",
      "}",
      -- And this, after it, lies in that part too.
      "int after(void) { return mid(8); }",
    })
    local many, calls = {}, {}
    for i = 1, 45 do
      local name = ("a_rather_long_function_name_%02d"):format(i)
      many[#many + 1] = ("int %s(void) { return %d; }"):format(name, i)
      calls[#calls + 1] = name .. "()"
    end
    many[#many + 1] = "int many(void) { return " .. table.concat(calls, " + ") .. "; }"
    write(dir .. "/c.c", many)
    run({ "gtags" }, dir)
    local seen = {}
    local function settled()
      vim.wait(10000, function()
        local lines = tree.lines()
        return #lines > 0 and not table.concat(lines, "\n"):find("…")
      end, 20)
      return tree.lines()
    end
    local function open_row(n)
      tree.expand(Snacks.picker.get({ source = "call_tree" })[1]:items()[n].node)
    end
    local ok, err = pcall(function()
      vim.cmd.edit(dir .. "/a.c")
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      key("<leader>jh")()
      seen.callers = settled()
      -- top, which no one calls: opened, it says so.
      open_row(3)
      settled()
      open_row(2)
      seen.mid = settled()
      -- CALL_MID, under mid: the functions that reach mid through it.
      open_row(5)
      seen.macro = settled()
      -- Enter goes to where the row's function makes the call.
      local picker = Snacks.picker.get({ source = "call_tree" })[1]
      picker.list:view(3)
      picker:action("confirm")
      seen.jumped = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
      -- L: every branch below a row, three levels down.
      local function open_all()
        local finished = false
        tree.expand_all(Snacks.picker.get({ source = "call_tree" })[1]:items()[1].node, function()
          finished = true
        end)
        vim.wait(10000, function()
          return finished
        end, 20)
        return settled()
      end
      seen.all = open_all()
      tree.close()
      -- And it stops once it has added as many rows as it may.
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      key("<leader>jh")()
      settled()
      local rows = tree.limits.rows
      tree.limits.rows = 2
      local capped_ok, capped = pcall(open_all)
      tree.limits.rows = rows
      seen.capped = capped_ok and capped[1] or tostring(capped)
      tree.close()

      vim.api.nvim_win_set_cursor(0, { 3, 5 })
      key("<leader>jH")()
      seen.callees = settled()
      tree.close()
      -- On a word that is not a function, the function the cursor is in.
      vim.api.nvim_win_set_cursor(0, { 4, 30 })
      key("<leader>jH")()
      seen.recursive = settled()
      tree.close()
      key("<leader>jh")()
      seen.recursive_up = settled()
      tree.close()
      vim.cmd.edit(dir .. "/c.c")
      vim.api.nvim_win_set_cursor(0, { 46, 5 })
      key("<leader>jH")()
      seen.many = settled()
      tree.close()
    end)
    reset_editor()
    expect(ok, tostring(err))
    local function same(got, want, what)
      expect(table.concat(got, "\n") == table.concat(want, "\n"), what .. ":\n" .. table.concat(got, "\n"))
    end
    same(seen.callers, {
      "▾ leaf  @a.c:1",
      "├╴▸ mid  @a.c:2",
      "├╴▸ top  @a.c:3",
      "└╴▸ split_type  @a.c:8",
    }, "callers of leaf")
    same(seen.mid, {
      "▾ leaf  @a.c:1",
      "├╴▾ mid  @a.c:2",
      "│ ├╴▸ top  @a.c:3",
      "│ ├╴▸ other  @b.c:2",
      "│ ├╴▸ CALL_MID  macro  @b.c:3",
      "│ ├╴▸ broken  ×2  @d.c:9",
      "│ └╴▸ after  @d.c:16",
      "├╴  top  no callers  @a.c:3",
      "└╴▸ split_type  @a.c:8",
    }, "callers of mid, opened under leaf")
    expect(
      vim.tbl_contains(seen.macro, "│ │ └╴▸ via_macro  @b.c:4"),
      "under CALL_MID:\n" .. table.concat(seen.macro, "\n")
    )
    expect(seen.jumped == "a.c:3", "Enter on top went to " .. tostring(seen.jumped))
    same(seen.all, {
      "▾ leaf  @a.c:1",
      "├╴▾ mid  @a.c:2",
      "│ ├╴  top  no callers  @a.c:3",
      "│ ├╴  other  no callers  @b.c:2",
      "│ ├╴▾ CALL_MID  macro  @b.c:3",
      -- The third level below, shown but not opened.
      "│ │ └╴▸ via_macro  @b.c:4",
      "│ ├╴  broken  ×2  no callers  @d.c:9",
      "│ └╴  after  no callers  @d.c:16",
      "├╴  top  no callers  @a.c:3",
      "└╴▾ split_type  @a.c:8",
      "  └╴  top  no callers  @a.c:3",
    }, "L on leaf")
    expect(seen.capped == "▾ leaf  opened until 2 rows  @a.c:1", "L stopped at 2 rows: " .. tostring(seen.capped))
    -- A click opens a branch on its ▸ only, not on the guide before it (whose
    -- first byte ▸ shares) or on the name. Columns are bytes, as getmousepos()
    -- gives them: " ├╴▸ mid" has ▸ at 8.
    local clicks = {}
    for _, column in ipairs({ 2, 5, 8, 10, 12 }) do
      clicks[#clicks + 1] = tostring(tree.on_mark(" ├╴▸ mid", column))
    end
    expect(table.concat(clicks, " ") == "false false true true false", "on the mark: " .. table.concat(clicks, " "))
    same(seen.callees, {
      "▾ top  @a.c:3",
      "├╴▸ mid  @a.c:3",
      "├╴▸ leaf  @a.c:3",
      "├╴  printf  not in GTAGS  @a.c:3",
      -- Defined with its type on the line above its name.
      "└╴▸ split_type  @a.c:3",
    }, "callees of top")
    same(seen.recursive, { "▾ rec  @a.c:4", "└╴  rec  ↻  @a.c:4" }, "callees of rec")
    same(seen.recursive_up, { "▾ rec  @a.c:4", "└╴  rec  ↻  @a.c:4" }, "callers of rec")
    local unknown = vim.tbl_filter(function(line)
      return line:find("not in GTAGS")
    end, seen.many)
    expect(#seen.many == 46 and #unknown == 0, ("callees of many: %d rows, %d not found"):format(#seen.many, #unknown))
  end)

  -- The panel knows a source only by the interface at the top of
  -- lua/config/call_tree.lua. One that answers from a graph in memory, after a
  -- turn of the event loop as a language server would, is drawn and opened as
  -- GTAGS is; a source that cannot answer for the buffer passes to the next,
  -- and when none can, the first one's reason is shown.
  check("call tree: a source that keeps to the interface is drawn as GTAGS is", function()
    local tree = require("config.call_tree")
    -- parse calls itself through expr: only the rows above tell it.
    local graph =
      { main = { "parse", "print", "missing" }, parse = { "next_token", "expr" }, expr = { "parse" }, print = {} }
    local asked = {}
    local function node(name, line)
      return {
        name = name,
        kind = graph[name] and "function" or "unknown",
        file = "/src/" .. name .. ".x",
        lnum = 1,
        sites = { { file = "/src/main.x", lnum = line } },
      }
    end
    package.loaded["call_tree_test.none"] = {
      attach = function()
        return nil, "no server for this buffer"
      end,
    }
    package.loaded["call_tree_test.graph"] = {
      attach = function()
        return {
          unknown = "not on the server",
          start = function(_, _, done)
            done({ name = "main", kind = "function", file = "/src/main.x", lnum = 1 })
          end,
          children = function(_, parent, direction, done)
            asked[#asked + 1] = direction .. ":" .. parent.name
            vim.schedule(function()
              local out = {}
              for line, name in ipairs(graph[parent.name] or {}) do
                out[#out + 1] = node(name, line + 1)
              end
              done(out)
            end)
          end,
          branches = function(_, parent)
            return parent.kind == "function"
          end,
        }
      end,
    }
    local sources = tree.sources
    local notify = vim.notify
    local seen = {}
    local ok, err = pcall(function()
      local function settled()
        vim.wait(3000, function()
          local lines = tree.lines()
          return #lines > 0 and not table.concat(lines, "\n"):find("…")
        end, 20)
        return tree.lines()
      end
      tree.sources = { "call_tree_test.none", "call_tree_test.graph" }
      tree.start("callers")
      settled()
      tree.expand(Snacks.picker.get({ source = "call_tree" })[1]:items()[2].node)
      settled()
      tree.expand(Snacks.picker.get({ source = "call_tree" })[1]:items()[4].node)
      seen.tree = settled()
      Snacks.picker.get({ source = "call_tree" })[1]:action("call_turn")
      settled()
      seen.title = Snacks.picker.get({ source = "call_tree" })[1].title
      tree.close()
      vim.notify = function(message)
        seen.message = message
      end
      tree.sources = { "call_tree_test.none" }
      tree.start("callers")
    end)
    tree.sources, vim.notify = sources, notify
    package.loaded["call_tree_test.none"], package.loaded["call_tree_test.graph"] = nil, nil
    reset_editor()
    expect(ok, tostring(err))
    local function same(got, want, what)
      expect(table.concat(got, "\n") == table.concat(want, "\n"), what .. ":\n" .. table.concat(got, "\n"))
    end
    same(seen.tree, {
      "▾ main  @main.x:1",
      "├╴▾ parse  @main.x:2",
      "│ ├╴  next_token  not on the server  @main.x:2",
      "│ └╴▾ expr  @main.x:3",
      "│   └╴  parse  ↻  @main.x:2",
      "├╴▸ print  @main.x:3",
      "└╴  missing  not on the server  @main.x:4",
    }, "the tree from a graph in memory")
    expect(seen.title == "Callees of main", "turned round: " .. tostring(seen.title))
    expect(
      table.concat(asked, " ") == "callers:main callers:parse callers:expr callees:main",
      "asked the source: " .. table.concat(asked, " ")
    )
    expect(seen.message == "no server for this buffer", "with no source to answer: " .. tostring(seen.message))
  end)

  -- The jump stack is Vim's tag stack, onto which every kind of jump goes, so
  -- it is the same for any language: here a jump in C, then one in Lua, each
  -- level named by the function it was made from. A headless run moves no
  -- cursor through the screen, so what CursorMoved would call is called here.
  check("jump stack: the jumps the cursor is inside, in C and Lua alike", function()
    local stack = require("config.jump_stack")
    local pins = require("config.pins")
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
      "  └╴run  → greet  @b.lua:5",
      "●   └╴greet  @b.lua:2",
    }, "after a jump in C and one in Lua")
    same(seen.popped, {
      "  broken  → helper  @c.c:8",
      "● └╴run  → greet  @b.lua:5",
      "    └╴greet  @b.lua:2",
    }, "back a level")
    expect(seen.visited == "c.c:8 at level 2", "showing the first level: " .. tostring(seen.visited))
    expect(seen.nothing == 0, "an empty chain pinned " .. tostring(seen.nothing))
    same(seen.pinned or {}, { "0:broken → helper", "1:run → greet", "2:greet" }, "the levels pinned")
    expect(seen.back == "c.c:8 at level 1", "back to the first level: " .. tostring(seen.back))
    expect(seen.cleared == 0, "rows left after emptying the stack: " .. tostring(seen.cleared))
  end)

  check("words: several words stay lit across files and windows, and are stepped through", function()
    local words = require("config.words")
    local dir = temp_dir()
    write(dir .. "/a.c", { "int len = 0;", "int buflen = len + 1;", "return len;" })
    write(dir .. "/b.c", { "size_t len;", "len = 2;" })
    local function lit(win)
      local names = {}
      for _, match in ipairs(vim.fn.getmatches(win)) do
        names[#names + 1] = match.group .. "=" .. match.pattern
      end
      table.sort(names)
      return table.concat(names, " ")
    end
    vim.cmd.edit(dir .. "/a.c")
    vim.fn.cursor(1, 5)
    key("<leader>hh")()
    vim.fn.cursor(1, 1)
    key("<leader>hh")()
    local two = lit(0)
    vim.cmd.edit(dir .. "/b.c")
    local other_file = lit(0)
    vim.cmd("vsplit")
    local new_window = lit(0)
    vim.cmd("close")
    vim.fn.cursor(1, 1)
    key("<leader>hn")()
    local first = vim.fn.line(".") .. ":" .. vim.fn.col(".")
    key("<leader>hn")()
    local second = vim.fn.line(".") .. ":" .. vim.fn.col(".")
    -- The panel lists every place in the open files as a tree with counts,
    -- jumps from a line, follows a file opened later, and follows the words
    -- as they are put out.
    key("<leader>ho")()
    local panel = Snacks.picker.get({ source = "words" })[1]
    expect(panel ~= nil, "the words panel did not open")
    local function rows()
      vim.wait(300)
      vim.wait(3000, function()
        return not panel:is_active()
      end, 50)
      local out = {}
      for _, item in ipairs(panel:items()) do
        if item.kind == "line" then
          out[#out + 1] = item.word.label .. "@" .. vim.fs.basename(item.file) .. ":" .. item.pos[1]
        else
          out[#out + 1] = item.kind
            .. ":"
            .. (item.kind == "word" and item.word.label or vim.fs.basename(item.file))
            .. "="
            .. item.count
        end
      end
      return out
    end
    local listed = table.concat(rows(), " ")
    vim.cmd("wincmd p")
    write(dir .. "/c.c", { "int len;" })
    vim.cmd.edit(dir .. "/c.c")
    local after_open = #rows()
    vim.api.nvim_set_current_win(panel.list.win.win)
    local last
    for index, item in ipairs(panel:items()) do
      if item.kind == "line" then
        last = index
      end
    end
    panel.list:view(last)
    panel:action("confirm")
    vim.wait(300)
    local jumped = vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    vim.api.nvim_set_current_win(panel.list.win.win)
    panel.list:view(1)
    panel:action("word_out")
    local rows_after = #rows()
    panel:close()
    vim.cmd("wincmd p")
    local one = lit(vim.api.nvim_get_current_win())
    words.clear()
    local none = lit(0)
    reset_editor()
    expect(two == [[Word1=\V\<len\> Word2=\V\<int\>]], "two words lit: " .. two)
    expect(other_file == two, "in another file: " .. other_file)
    expect(new_window == two, "in a new window: " .. new_window)
    expect(first == "1:8" and second == "2:1", ("stepping landed on %s then %s"):format(first, second))
    expect(
      listed
        == "word:len=5 file:a.c=3 len@a.c:1 len@a.c:2 len@a.c:3 file:b.c=2 len@b.c:1 len@b.c:2 word:int=2 file:a.c=2 int@a.c:1 int@a.c:2",
      "the panel listed: " .. listed
    )
    expect(after_open == 16, ("after opening a third file the panel has %d rows, not 16"):format(after_open))
    expect(jumped == "c.c:1", "Enter on the last line went to " .. jumped)
    expect(rows_after == 6, ("after dd on len the panel has %d rows, not 6"):format(rows_after))
    expect(one == [[Word2=\V\<int\>]], "after putting len out: " .. one)
    expect(none == "", "after clearing: " .. none)
  end)

  -- A whole run starts a few dozen processes. Thousands mean something feeds
  -- itself: it was gitsigns once, starting git over a thousand times in a few
  -- seconds and leaving a Neovim that would not exit.
  check("nothing starts processes without end", function()
    for name, count in pairs(spawned) do
      expect(count < 300, ("%s was started %d times"):format(name, count))
    end
  end)
end

vim.defer_fn(function()
  local ok, err = pcall(run_checks)
  pcall(reset_editor)
  -- Step out of the directories about to be removed, but not into a repository.
  vim.api.nvim_set_current_dir(vim.fs.dirname(neutral_dir))
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end

  local failed, skipped = 0, 0
  local lines = { "" }
  for _, result in ipairs(results) do
    lines[#lines + 1] = ("%-5s %4.1fs  %s%s"):format(
      result.status,
      result.seconds,
      result.name,
      result.detail and ("\n             " .. result.detail) or ""
    )
    failed = failed + (result.status == "FAIL" and 1 or 0)
    skipped = skipped + (result.status == "skip" and 1 or 0)
  end
  if not ok then
    failed = failed + 1
    lines[#lines + 1] = "FAIL  the run itself stopped: " .. tostring(err)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d checks, %d failed, %d skipped"):format(#results, failed, skipped)
  io.stdout:write(table.concat(lines, "\n") .. "\n")
  io.stdout:flush()
  vim.cmd(failed == 0 and "qa!" or ("cquit " .. failed))
end, 3000)

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
    local script = ([[lua vim.wait(8000, function() return #vim.fn.sign_getplaced(1, { group = "*" })[1].signs > 0 end, 100) local rows = {} for _, s in ipairs(vim.fn.sign_getplaced(1, { group = "*" })[1].signs) do rows[#rows + 1] = s.lnum .. ":" .. s.name end vim.fn.writefile({ table.concat(rows, " ") }, %q)]]):format(
      out
    )
    local child = vim
      .system({ vim.v.progpath, "--headless", "-n", dir .. "/wc/a.c", "-c", script, "-c", "qa!" }, { cwd = dir, text = true })
      :wait(40000)
    expect(
      child.code == 0 and vim.uv.fs_stat(out) ~= nil,
      "the child did not finish (exit " .. tostring(child.code) .. ")"
    )
    local svn_marks = table.concat(vim.fn.readfile(out), "")
    expect(svn_marks == "2:SignifyChange 6:SignifyAdd", "marks on the first file read: " .. svn_marks)
    expect(vim.fn.maparg("]h", "n") ~= "", "]h is not mapped")
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
    reset_editor()
    expect(landed == "lib.c:1", "landed on " .. landed)
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

    Snacks.picker.qflist = real_qflist
    reset_editor()
    expect(word_many == "dup_fn" and word_one == "only_fn", "the cursor was on " .. word_many .. " and " .. word_one)
    expect(table.concat(listed, " ") == "a.c:2 b.c:1", "listed: " .. table.concat(listed, " "))
    expect(landed == "d.c:3", "landed on " .. landed)
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

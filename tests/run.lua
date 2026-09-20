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
    -- Let go of the repository before it is removed from under the watcher.
    gitsigns.detach_all()
    reset_editor()
    expect(fileformat == "unix", "the buffer stayed " .. fileformat .. ", so this check proves nothing")
    expect(untouched == 0, ("%d of 30 untouched lines are marked as changed"):format(untouched))
    expect(after_edit >= 1, "a real edit is no longer marked")
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

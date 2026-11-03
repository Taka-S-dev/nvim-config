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
    -- Space pressed in Normal mode with the input method on comes as a
    -- full-width space: it turns the input method off and goes on as Space.
    -- In Insert mode it is text.
    local fed, notify, feedkeys = {}, vim.notify, vim.api.nvim_feedkeys
    local ok, err = pcall(function()
      -- The input method is turned off once the change is done, so this waits
      -- a moment for each.
      local function change_to(change)
        local before = calls
        vim.api.nvim_exec_autocmds("ModeChanged", { pattern = change })
        vim.wait(30, function()
          return calls > before
        end, 5)
        return change .. "=" .. (calls > before and "off" or "-")
      end
      for _, change in ipairs(changes) do
        seen[#seen + 1] = change_to(change)
      end
      -- Out of Insert mode and straight back, as the grep picker does to draw
      -- its preview for every character typed: the input method stays on.
      local get_mode = vim.api.nvim_get_mode
      vim.api.nvim_get_mode = function()
        return { mode = "i", blocking = false }
      end
      local back = change_to("i:n")
      vim.api.nvim_get_mode = get_mode
      seen[#seen + 1] = "back:" .. back
      vim.notify = function() end
      vim.api.nvim_feedkeys = function(keys)
        fed[#fed + 1] = keys
      end
      local before = calls
      for _, mode in ipairs({ "n", "x" }) do
        vim.fn.maparg("\u{3000}", mode, false, true).callback()
      end
      fed.off = calls - before
      fed.insert = vim.fn.maparg("\u{3000}", "i") == ""
    end)
    ime.off, vim.notify, vim.api.nvim_feedkeys = off, notify, feedkeys
    expect(ok, tostring(err))
    expect(ime.available(), "the Windows API could not be loaded")
    expect(
      table.concat(seen, " ") == "i:n=off c:n=off R:n=off i:ic=- i:niI=- ic:i=- n:i=- i:c=- back:i:n=-",
      "turned off on: " .. table.concat(seen, " ")
    )
    expect(
      fed.off == 2 and fed[1] == " " and fed[2] == " " and fed.insert,
      "the full-width space: " .. vim.inspect(fed)
    )
  end)
  -- The indent is taken from the file: LazyVim's two drew two guides to a
  -- level of openssl's four, and laid tabs out two wide. Tabs are four wide,
  -- as VS Code shows them.
  check("indent: taken from each file, tabs four wide, the guides thin", function()
    local dir = temp_dir()
    write(dir .. "/four.c", { "int f(void)", "{", "    if (a) {", "        b();", "    }", "}" })
    write(dir .. "/tabs.c", { "int f(void)", "{", "\tif (a) {", "\t\tb();", "\t}", "}" })
    write(dir .. "/two.lua", { "local t = {", "  a = {", "    b = 1,", "  },", "}" })
    local seen = {}
    local ok, err = pcall(function()
      for _, name in ipairs({ "four.c", "tabs.c", "two.lua" }) do
        vim.cmd.edit(dir .. "/" .. name)
        seen[#seen + 1] = ("%s sw=%d ts=%d et=%s"):format(
          name,
          vim.fn.shiftwidth(),
          vim.bo.tabstop,
          tostring(vim.bo.expandtab)
        )
      end
    end)
    vim.cmd("silent! %bwipeout!")
    reset_editor()
    expect(ok, tostring(err))
    expect(
      table.concat(seen, " | ") == "four.c sw=4 ts=4 et=true | tabs.c sw=4 ts=4 et=false | two.lua sw=2 ts=2 et=true",
      "indents: " .. table.concat(seen, " | ")
    )
    -- The guides thin: a box-drawing line, drawn by the terminal, read heavy.
    expect(
      Snacks.config.indent.indent.char == "▏" and Snacks.config.indent.scope.char == "▏",
      "guides: " .. Snacks.config.indent.indent.char .. " " .. Snacks.config.indent.scope.char
    )
  end)
  -- Updates to plugins are not looked for as the editor starts: the checker
  -- started git once for each plugin, 46 processes, and where every process
  -- start is inspected that was most of what a start cost.
  check("startup: no checking for plugin updates", function()
    local config = require("lazy.core.config").options
    expect(config.checker.enabled == false, "the update checker is on")
  end)
  -- The results of grug-far are searched again when a file is saved: a line
  -- deleted from a file stayed in the list until searched again by hand.
  check("grug-far: the results follow a file saved", function()
    need("rg")
    local dir = temp_dir()
    write(dir .. "/a.c", { "int keepme;", "int dropme_one;", "int dropme_two;" })
    write(dir .. "/b.c", { "int dropme_three;" })
    local cwd = vim.fn.getcwd()
    local seen = {}
    local function results()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "grug-far" then
          return #vim.tbl_filter(function(line)
            return line:find("dropme_") ~= nil
          end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end
      end
      return -1
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/a.c")
      local code = vim.api.nvim_get_current_win()
      require("grug-far").open({ prefills = { search = "dropme" } })
      vim.wait(10000, function()
        return results() == 3
      end, 50)
      seen[#seen + 1] = results()
      vim.api.nvim_set_current_win(code)
      vim.cmd("2delete")
      vim.cmd("silent write")
      vim.wait(10000, function()
        return results() == 2
      end, 50)
      seen[#seen + 1] = results()
    end)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "grug-far" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    vim.cmd("silent! %bwipeout!")
    vim.api.nvim_set_current_dir(cwd)
    reset_editor()
    expect(ok, tostring(err))
    expect(vim.deep_equal(seen, { 3, 2 }), "matches before and after the save: " .. vim.inspect(seen))
  end)
  -- <leader>sr keeps one search, put away with q or <leader>sr and brought back
  -- as it was: its text, its paths and its filter. LazyVim's opened a fresh one
  -- each time, and the paths were typed again at every opening. \d sets the
  -- paths to the folder of the file it was opened from.
  check("grug-far: <leader>sr keeps the search, and \\d searches the file's folder", function()
    need("rg")
    local dir = temp_dir()
    write(dir .. "/sub/a.c", { "int findme;" })
    write(dir .. "/b.c", { "int findme;" })
    local cwd = vim.fn.getcwd()
    local seen = {}
    local grug_far
    local function values()
      local instance = grug_far.get_instance("main")
      local v = require("grug-far.inputs").getValues(instance._context, instance._buf)
      return ("%s|%s|%s"):format(v.search or "", v.paths or "", v.filesFilter or "")
    end
    local function buf_key(lhs)
      local buf = grug_far.get_instance("main")._buf
      return vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true).callback
      end)
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/sub/a.c")
      T.key("<leader>sr")()
      grug_far = require("grug-far")
      vim.wait(5000, function()
        return grug_far.is_instance_open("main")
      end, 20)
      vim.wait(300)
      grug_far.update_instance_prefills("main", { search = "findme" }, false)
      buf_key("<localleader>d")()
      vim.wait(5000, function()
        local s = grug_far.get_instance("main"):get_status_info()
        return s.status == "success" and s.stats and s.stats.matches == 1
      end, 50)
      seen.narrowed = values()
      seen.listed = vim.bo[grug_far.get_instance("main")._buf].buflisted
      buf_key("q")()
      vim.wait(200)
      seen.away = grug_far.has_instance("main") and not grug_far.is_instance_open("main")
      T.key("<leader>sr")()
      vim.wait(2000, function()
        return grug_far.is_instance_open("main")
      end, 20)
      seen.back = values()
    end)
    if grug_far and grug_far.has_instance("main") then
      grug_far.kill_instance("main")
    end
    vim.cmd("silent! %bwipeout!")
    vim.api.nvim_set_current_dir(cwd)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.narrowed == "findme|sub/|*.c", "after \\d: " .. tostring(seen.narrowed))
    expect(seen.listed == false, "the search is among the open buffers")
    expect(seen.away, "q did not put the search away and keep it")
    expect(seen.back == "findme|sub/|*.c", "brought back: " .. tostring(seen.back))
  end)
  -- What is typed after ` -- ` in the grep picker goes to rg once it is
  -- whole: on `findme -- -g`, the glob not typed yet, rg took the `--` that
  -- closes the options for the glob, and its output, nothing the picker could
  -- read, put up a message for each line.
  check("grep: an rg option still being typed is left out until it is whole", function()
    need("rg")
    local parse = require("snacks.picker.util").parse
    local function args(text)
      return table.concat(select(2, parse(text)), " ")
    end
    local split = {
      args("findme -- -g"),
      args("findme -- -g *.c"),
      args("findme -- -i"),
      args("findme -- -"),
      args("findme -- --glob=*.c"),
      args("findme -- -i -t"),
    }
    local dir = temp_dir()
    write(dir .. "/a.c", { "int findme;" })
    write(dir .. "/b.h", { "int findme;" })
    local cwd = vim.fn.getcwd()
    local notify = vim.notify
    local complaints = 0
    local found
    local ok, err = pcall(function()
      vim.notify = function(message, ...)
        if tostring(message):find("invalid grep output", 1, true) then
          complaints = complaints + 1
        end
        return notify(message, ...)
      end
      vim.api.nvim_set_current_dir(dir)
      local picker = Snacks.picker.grep({ search = "findme -- -g" })
      vim.wait(3000, function()
        return not picker:is_active()
      end, 20)
      vim.wait(200)
      found = #picker:items()
      picker:close()
    end)
    vim.notify = notify
    vim.api.nvim_set_current_dir(cwd)
    reset_editor()
    expect(ok, tostring(err))
    expect(
      vim.deep_equal(split, { "", "-g *.c", "-i", "", "--glob=*.c", "-i" }),
      "options passed: " .. vim.inspect(split)
    )
    expect(found == 2, "findme -- -g found " .. tostring(found))
    expect(complaints == 0, ("%d messages of output the picker could not read"):format(complaints))
  end)
  -- Each tab searches what it was given: a folder chosen from a list with
  -- Alt+., kinds of file chosen with Alt+e, in a grep or a file search, kept
  -- for the tab until changed, and shown in the statusline. A new tab starts
  -- with none. The list puts the file's folder first and the whole project
  -- next; a path pasted is taken as it is. Esc leaves the tab's as it was.
  check("scope: each tab keeps the folder and kinds chosen for its searches", function()
    need("rg")
    local dir = vim.fs.normalize(temp_dir())
    write(dir .. "/sub/deep/a.c", { "int findme;" })
    write(dir .. "/sub/deep/a.txt", { "findme" })
    write(dir .. "/sub/b.c", { "int findme;" })
    write(dir .. "/sub/b.h", { "int findme;" })
    write(dir .. "/top.c", { "int findme;" })
    local scope = require("taka.scope")
    local grep_folder = require("taka.grep_folder")
    local bs = string.char(92)
    local cases = {
      { "sub/deep/", dir .. "/sub/deep" },
      { (dir .. "/sub/deep"):gsub("/", bs), dir .. "/sub/deep" },
      { '"sub/b.c"', dir .. "/sub" },
      { ".", dir },
      { "", dir .. "/sub" },
      { "no/such", nil },
    }
    local got = {}
    for _, case in ipairs(cases) do
      got[#got + 1] = tostring((grep_folder.folder(case[1], dir, dir .. "/sub")))
    end
    local cwd = vim.fn.getcwd()
    local grep = Snacks.picker.grep
    local seen = {}
    local function now()
      return scope.describe(scope.get())
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/sub/b.c")
      -- From a grep for findme, the list `source` opened by its key; `typed`
      -- put in it then Enter, or `rows` picked with Tab then Enter, or the
      -- list closed when both are nil. The search opened again is returned.
      local function choose(action, source, typed, rows)
        local picker = grep({ search = "findme" })
        vim.wait(3000, function()
          return not picker:is_active()
        end, 20)
        local opened
        Snacks.picker.grep = function(opts)
          opened = opts
        end
        picker:action(action)
        local list
        vim.wait(3000, function()
          list = Snacks.picker.get({ source = source })[1]
          return list ~= nil and not list:is_active()
        end, 20)
        seen[source] = seen[source] or vim.tbl_map(function(item)
          return item.text
        end, list:items())
        -- The title and the rows marked as the tab's, at each opening.
        seen.marked = { list.opts.title }
        for _, item in ipairs(list:items()) do
          if item.now then
            seen.marked[#seen.marked + 1] = item.text
          end
        end
        seen.first = list:items()[1].text
        if typed then
          vim.api.nvim_buf_set_lines(list.input.win.buf, 0, -1, false, { typed })
          vim.api.nvim_exec_autocmds("TextChanged", { buffer = list.input.win.buf })
          vim.wait(1000, function()
            return list.matcher.pattern == typed and not list:is_active()
          end, 10)
          list:action("confirm")
        elseif rows then
          for _, item in ipairs(list:items()) do
            if vim.tbl_contains(rows, item.text) then
              list.list:select(item)
            end
          end
          list:action("confirm")
        else
          list:close()
        end
        vim.wait(1000, function()
          return opened ~= nil
        end, 10)
        Snacks.picker.grep = grep
        return opened and opened.search
      end
      seen.at_once = choose("scope_folder", "grep_folders", "") .. " " .. now()
      seen.unpinned_first = seen.first
      seen.fuzzy = choose("scope_folder", "grep_folders", "dee") .. " " .. now()
      seen.pinned_first, seen.pinned = seen.first, seen.marked
      seen.pasted = choose("scope_folder", "grep_folders", (dir .. "/sub"):gsub("/", bs)) .. " " .. now()
      seen.given_up = choose("scope_folder", "grep_folders", nil) .. " " .. now()
      seen.kinds = choose("scope_kinds", "grep_kinds", nil, { "*.c", "*.h" }) .. " " .. now()
      choose("scope_kinds", "grep_kinds", nil)
      seen.kinds_marked = seen.marked
      -- The searches of the tab keep to it: rg is given the folder and the
      -- globs once, though snacks runs the hook more than once.
      local search = grep({ search = "findme" })
      vim.wait(3000, function()
        return not search:is_active()
      end, 20)
      seen.grep_args = table.concat(search.opts.args or {}, " ")
      -- The two keys are named at the foot of the search's frame.
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local footer = vim.api.nvim_win_get_config(win).footer
        if type(footer) == "table" and #footer > 0 then
          local text = table.concat(vim.tbl_map(function(chunk)
            return chunk[1]
          end, footer))
          seen.footer = vim.trim(text):gsub("%s+", " ")
        end
      end
      seen.found = vim.tbl_map(function(item)
        return item.file:gsub(bs, "/")
      end, search:items())
      table.sort(seen.found)
      search:close()
      local files = Snacks.picker.files()
      vim.wait(3000, function()
        return not files:is_active()
      end, 20)
      seen.files = vim.tbl_map(function(item)
        return item.file:gsub(bs, "/")
      end, files:items())
      table.sort(seen.files)
      files:close()
      seen.status = scope.status():gsub("^%S+ ", "")
      -- Another tab searches the whole project; the first keeps its own.
      vim.cmd.tabnew()
      seen.other_tab = now()
      vim.cmd.tabprevious()
      seen.first_tab = now()
      vim.cmd.tabclose({ range = { 2 } })
      choose("scope_folder", "grep_folders", ".")
      seen.whole = now()
      vim.cmd("Scope off")
      seen.off = now()
    end)
    Snacks.picker.grep = grep
    for _, picker in ipairs(Snacks.picker.get()) do
      picker:close()
    end
    scope.clear()
    vim.api.nvim_set_current_dir(cwd)
    reset_editor()
    expect(ok, tostring(err))
    local want = {}
    for _, case in ipairs(cases) do
      want[#want + 1] = tostring(case[2])
    end
    expect(vim.deep_equal(got, want), "folders: " .. vim.inspect(got))
    expect(
      vim.deep_equal(seen.grep_folders, { "sub/", "./", "sub/deep/" }),
      "the folders listed: " .. vim.inspect(seen.grep_folders)
    )
    expect(seen.at_once == "findme sub/", "Enter at once: " .. tostring(seen.at_once))
    expect(seen.unpinned_first == "sub/", "first with no folder kept: " .. tostring(seen.unpinned_first))
    expect(seen.pinned_first == "./", "first with sub/ kept: " .. tostring(seen.pinned_first))
    expect(
      vim.deep_equal(seen.pinned, { "Folder this tab searches (now sub/)", "sub/" }),
      "the folder kept, marked: " .. vim.inspect(seen.pinned)
    )
    expect(
      vim.deep_equal(seen.kinds_marked, { "Kinds of file this tab searches (now *.c *.h; Tab: several)", "*.c *.h" }),
      "the kinds kept, marked: " .. vim.inspect(seen.kinds_marked)
    )
    expect(seen.fuzzy == "findme sub/deep/", "dee chosen: " .. tostring(seen.fuzzy))
    expect(seen.pasted == "findme sub/", "a path pasted: " .. tostring(seen.pasted))
    expect(seen.given_up == "findme sub/", "given up: " .. tostring(seen.given_up))
    expect(
      vim.deep_equal(seen.grep_kinds, { "every kind", "*.c *.h", "*.c", "*.h", "*.txt" }),
      "the kinds listed under sub/: " .. vim.inspect(seen.grep_kinds)
    )
    expect(seen.kinds == "findme sub/ *.c *.h", "kinds chosen: " .. tostring(seen.kinds))
    expect(seen.grep_args == "-g *.c -g *.h", "rg given: " .. tostring(seen.grep_args))
    expect(seen.footer == "Alt+. folder Alt+e kinds", "the keys named: " .. tostring(seen.footer))
    expect(
      vim.deep_equal(seen.found, { "sub/b.c", "sub/b.h", "sub/deep/a.c" }),
      "grep found: " .. vim.inspect(seen.found)
    )
    expect(
      vim.deep_equal(seen.files, { "sub/b.c", "sub/b.h", "sub/deep/a.c" }),
      "files listed: " .. vim.inspect(seen.files)
    )
    expect(seen.status == "sub/ *.c *.h", "statusline: " .. tostring(seen.status))
    expect(seen.other_tab == "", "a new tab searches: " .. tostring(seen.other_tab))
    expect(seen.first_tab == "sub/ *.c *.h", "back in the first tab: " .. tostring(seen.first_tab))
    expect(seen.whole == "*.c *.h", ". takes the folder off: " .. tostring(seen.whole))
    expect(seen.off == "", ":Scope off left: " .. tostring(seen.off))
  end)
  -- The grep has VS Code's three buttons for how it matches, with its keys:
  -- the case typed always (Alt+c), whole words (Alt+w) and the pattern or
  -- the text as it is (Alt+r), lit while on. What a grep was set to is kept
  -- for the next; <leader>sw starts with whole words and the text as it is,
  -- and leaves the next grep as it was. Alt+o moves between the windows, as
  -- Alt+w did. The clicks on the buttons are read off the screen, which a
  -- headless run has none of.
  check("grep: buttons and keys for the case, whole words and the pattern", function()
    need("rg")
    local dir = vim.fs.normalize(temp_dir())
    write(dir .. "/a.c", { "int len;", "int LEN;", "int strlen;", "int l.n;" })
    local match = require("taka.grep_match")
    local cwd = vim.fn.getcwd()
    local seen = {}
    local function open(source, search)
      local picker = Snacks.picker[source]({ search = search })
      -- The search can be done before the window it is typed in is open, and
      -- the buttons are drawn after that.
      vim.wait(3000, function()
        return not picker:is_active() and picker.input.win.buf ~= nil and match.shown(picker) ~= ""
      end, 20)
      return picker
    end
    local function look(picker, action)
      if action then
        picker:action(action)
        vim.wait(100)
        vim.wait(3000, function()
          return not picker:is_active()
        end, 20)
      end
      local lines = vim.tbl_map(function(item)
        return item.pos[1]
      end, picker:items())
      table.sort(lines)
      return match.shown(picker) .. " | " .. table.concat(lines, ",")
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/a.c")
      local picker = open("grep", "len")
      seen.start = look(picker)
      seen.case = look(picker, "grep_case")
      look(picker, "grep_case")
      seen.word = look(picker, "grep_word")
      look(picker, "grep_word")
      local buf = picker.input.win.buf
      seen.keys = {}
      for _, lhs in ipairs({ "<M-c>", "<M-w>", "<M-r>", "<M-o>" }) do
        seen.keys[#seen.keys + 1] = vim.fn.maparg(lhs, "i", false, true).buffer == 1
      end
      picker:close()
      picker = open("grep", "l.n")
      seen.pattern = look(picker)
      seen.text = look(picker, "grep_regex")
      picker:close()
      picker = open("grep", "l.n")
      seen.kept = look(picker)
      picker:close()
      picker = open("grep_word", "len")
      seen.word_source = look(picker)
      look(picker, "grep_case")
      picker:close()
      seen.options = vim.inspect(match.options, { newline = "" })
    end)
    for _, picker in ipairs(Snacks.picker.get()) do
      picker:close()
    end
    match.options = { case = false, word = false, regex = true }
    vim.api.nvim_set_current_dir(cwd)
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.start == "Aa ab [.*] | 1,2,3", "len: " .. tostring(seen.start))
    expect(seen.case == "[Aa] ab [.*] | 1,3", "len, its case: " .. tostring(seen.case))
    expect(seen.word == "Aa [ab] [.*] | 1,2", "len, whole words: " .. tostring(seen.word))
    expect(vim.deep_equal(seen.keys, { true, true, true, true }), "keys: " .. vim.inspect(seen.keys))
    expect(seen.pattern == "Aa ab [.*] | 1,2,3,4", "l.n as a pattern: " .. tostring(seen.pattern))
    expect(seen.text == "Aa ab .* | 4", "l.n as it is: " .. tostring(seen.text))
    expect(seen.kept == "Aa ab .* | 4", "the next grep: " .. tostring(seen.kept))
    expect(seen.word_source == "Aa [ab] .* | 1,2", "<leader>sw on len: " .. tostring(seen.word_source))
    expect(
      seen.options == "{  case = false,  regex = false,  word = false}",
      "kept for the next grep: " .. tostring(seen.options)
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

  -- The right click on the file tree opens a menu for the file clicked, its
  -- paths to copy among it, in place of the menu for code; Y copies the path
  -- relative to the cwd. Headless there is no mouse, so where it points is
  -- given, the menu itself is not drawn, and what is copied or opened is
  -- caught rather than done.
  check("explorer: the right click offers the file's paths, Y copies the relative one", function()
    local dir = temp_dir()
    T.write(dir .. "/sub/deep.c", { "int x;" })
    T.write(dir .. "/top.c", { "int y;" })
    local seen = { copied = {}, ran = {} }
    local explorer
    local setreg, getmousepos, cmd, system, spawn, open =
      vim.fn.setreg, vim.fn.getmousepos, vim.cmd, vim.system, vim.uv.spawn, vim.ui.open
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/sub/deep.c")
      Snacks.explorer()
      vim.wait(2000, function()
        explorer = Snacks.picker.get({ source = "explorer" })[1]
        return explorer and explorer:current() ~= nil
      end, 20)
      vim.wait(500)
      local win = explorer.list.win.win
      local function row_of(name)
        for i, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
          if line:find(name, 1, true) then
            return i
          end
        end
      end
      vim.fn.setreg = function(register, value)
        seen.copied[#seen.copied + 1] = register .. "=" .. value
      end
      vim.system = function(command)
        seen.ran[#seen.ran + 1] = "system " .. table.concat(command, " ")
        return {}
      end
      -- Explorer is started without vim.system, which hides the window of what
      -- it starts: Explorer's came up hidden, and never showed.
      vim.uv.spawn = function(command, options)
        seen.ran[#seen.ran + 1] = ("%s %s verbatim=%s hide=%s"):format(
          command,
          table.concat(options.args, " "),
          tostring(options.verbatim),
          tostring(options.hide)
        )
        return nil
      end
      vim.ui.open = function(path)
        seen.ran[#seen.ran + 1] = "open " .. path
      end
      vim.cmd = setmetatable({}, {
        __call = function(_, command)
          if type(command) == "string" and command:find("^popup") then
            seen.popup = command
            seen.popup_from = vim.bo.filetype
            return
          end
          return cmd(command)
        end,
        __index = cmd,
      })
      -- The right click on top.c, the cursor being on deep.c.
      local line = row_of("top.c")
      vim.fn.getmousepos = function()
        return { winid = win, line = line, column = 3 }
      end
      vim.api.nvim_set_current_win(win)
      require("taka.explorer_menu").open(explorer)
      seen.target = require("taka.explorer_menu").target()
      seen.current = vim.fs.basename(Snacks.picker.util.path(explorer:current()))
      seen.back = vim.api.nvim_get_current_win() == win
      for _, name in ipairs({ "copy_path", "copy_relative", "copy_name", "reveal", "open" }) do
        require("taka.explorer_menu").run(name)
      end
      -- Y on deep.c, in its folder.
      vim.fn.getmousepos = getmousepos
      explorer.list:move(row_of("deep.c"), true)
      vim.wait(100)
      vim.api.nvim_feedkeys("Y", "x", false)
      seen.keys = {
        right = vim.fn.maparg("<RightMouse>", "n", false, true).desc,
        Y = vim.fn.maparg("Y", "n", false, true).desc,
      }
      seen.menu = vim.fn.menu_info("]Explorer").submenus
    end)
    vim.fn.setreg, vim.fn.getmousepos, vim.cmd, vim.system, vim.uv.spawn, vim.ui.open =
      setreg, getmousepos, cmd, system, spawn, open
    if explorer and not explorer.closed then
      explorer:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    local full = vim.fs.normalize(dir) .. "/top.c"
    expect(seen.target == full, "the menu was opened on " .. tostring(seen.target))
    expect(seen.current == "top.c", "the row clicked is not the current one: " .. tostring(seen.current))
    expect(seen.popup == "popup! ]Explorer", "the menu opened was " .. tostring(seen.popup))
    -- From the code window: in the tree's list, j, <Down> and Enter are the
    -- list's own, and took the keys meant for the menu.
    expect(seen.popup_from == "c", "the menu opened from a " .. tostring(seen.popup_from) .. " window")
    expect(seen.back, "the tree was not gone back to after the menu")
    expect(
      vim.deep_equal(vim.list_slice(seen.copied, 1, 3), { "+=" .. full, "+=top.c", "+=top.c" }),
      "copied: " .. vim.inspect(seen.copied)
    )
    expect(seen.copied[4] == "+=sub/deep.c", "Y copied " .. tostring(seen.copied[4]))
    local reveal = vim.fn.has("win32") == 1
        and ('explorer.exe /select,"%s" verbatim=true hide=nil'):format((full:gsub("/", "\\")))
      or ("open " .. vim.fs.dirname(full))
    expect(vim.deep_equal(seen.ran, { reveal, "open " .. full }), "ran: " .. vim.inspect(seen.ran))
    expect(
      seen.keys and seen.keys.right == "explorer_menu" and seen.keys.Y == "explorer_yank_relative",
      "keys: " .. vim.inspect(seen.keys)
    )
    expect(seen.menu and #seen.menu == 6, "menu: " .. vim.inspect(seen.menu))
    -- Framed and not see-through: its background is the tree's, and it had no
    -- edge there, the names beneath showing between its words.
    local border = vim.api.nvim_get_hl(0, { name = "PmenuBorder", link = false }).fg
    local floats = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false }).fg
    expect(vim.o.pumborder == "rounded", "pumborder: " .. vim.o.pumborder)
    expect(vim.o.pumblend == 0, "pumblend: " .. vim.o.pumblend)
    expect(
      border ~= nil and border == floats,
      ("the menu's border is #%06x, the floats' #%06x"):format(border or 0, floats or 0)
    )
  end)

  -- <C-l> in the file tree goes to the code beside it. The picker keys that
  -- scroll a preview sideways took <C-l> in every picker, the tree among
  -- them, and there, with no preview, it did nothing.
  check("explorer: <C-l> in the tree goes to the code beside it", function()
    local dir = temp_dir()
    T.write(dir .. "/a.c", { "int x;" })
    local seen = {}
    local explorer
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      vim.cmd.edit(dir .. "/a.c")
      local code = vim.api.nvim_get_current_win()
      Snacks.explorer()
      vim.wait(2000, function()
        explorer = Snacks.picker.get({ source = "explorer" })[1]
        return explorer and explorer:current() ~= nil
      end, 20)
      vim.wait(300)
      vim.api.nvim_set_current_win(explorer.list.win.win)
      vim.cmd.stopinsert()
      seen.from = vim.bo.filetype
      vim.api.nvim_feedkeys(vim.keycode("<C-l>"), "x", false)
      seen.to = vim.api.nvim_get_current_win() == code and "code" or vim.bo.filetype
      -- A floating picker with its preview hidden stays open where it is:
      -- moving out of it would close it.
      explorer:close()
      local files = Snacks.picker.files({ cwd = dir })
      vim.wait(2000, function()
        return files:count() > 0 and not files:is_active()
      end, 20)
      files:action("toggle_preview")
      vim.wait(200)
      local at = vim.api.nvim_get_current_win()
      files:action("preview_scroll_right")
      vim.wait(200)
      seen.float_stayed = not files.closed and vim.api.nvim_get_current_win() == at
      files:close()
    end)
    if explorer and not explorer.closed then
      explorer:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.from == "snacks_picker_list", "pressed in " .. tostring(seen.from))
    expect(seen.to == "code", "<C-l> in the tree went to " .. tostring(seen.to))
    expect(seen.float_stayed, "<C-l> in a floating picker with no preview left it")
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
  -- <leader>cb: a number of C in every base, as flags and masks are read. The
  -- literal is told from a name or a float it is part of; an expression is
  -- worked out as C binds it; 64-bit values hold.
  check("radix: the number under the cursor or selected, in every base", function()
    local radix = require("taka.radix")
    local line = "if (flags & 0x0C) x = var2 + 1.5 + 0x1p3 + 42UL + 'A';"
    local found = {}
    for _, col in ipairs({ 14, 25, 32, 40, 45, 51 }) do
      found[#found + 1] = tostring((radix.literal_at(line, col)))
    end
    expect(
      table.concat(found, " ") == "0x0C nil nil nil 42UL 'A'",
      "literals at the columns: " .. table.concat(found, " ")
    )
    local function shown(lines)
      return lines and table.concat(lines, " | ") or "nil"
    end
    local want = {
      ["0x20000000U"] = "0x20000000U | dec  536,870,912 | hex  0x20000000 | bin  0b0010_0000_0000_0000_0000_0000_0000_0000 | bit  29 set (0=LSB)",
      ["010"] = "010  (octal) | dec  8 | hex  0x8 | bin  0b0000_1000 | bit  3 set (0=LSB)",
      ["089"] = "nil",
      ["'\\n'"] = "'\\n' | dec  10 | hex  0xa",
      ["18446744073709551615"] = "18446744073709551615 | dec  18,446,744,073,709,551,615 | hex  0xffffffffffffffff | bin  0b"
        .. ("1111_"):rep(15)
        .. "1111 | bit  64 bits set",
    }
    for text, lines in pairs(want) do
      local got = shown(radix.describe(text))
      expect(got == lines, text .. " was shown as " .. got)
    end
    local sums = {
      ["1 << 6 | 2"] = "1 << 6 | 2 | dec  66 | hex  0x42 | bin  0b0100_0010 | bit  6, 1 set (0=LSB)",
      ["1 & 2 == 2"] = "1 & 2 == 2 | true",
      ["3 - 5"] = "3 - 5 | dec  -2 | hex  0xfffffffffffffffe  (64-bit)",
      ["10 / 0"] = "nil",
      ["FOO | 1"] = "nil",
    }
    for source, lines in pairs(sums) do
      local got = shown(radix.calculate(source))
      expect(got == lines, source .. " was worked out as " .. got)
    end
    -- By the key: on a literal, and on an expression selected.
    local seen = {}
    local ok, err = pcall(function()
      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "if (flags & 0x0C) {", "m = (1 << 4) | 1;" })
      local function float_text()
        for _, win in ipairs(T.floats()) do
          local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), " | ")
          pcall(vim.api.nvim_win_close, win, true)
          return text
        end
      end
      vim.api.nvim_win_set_cursor(0, { 1, 14 })
      T.key("<leader>cb")()
      seen[#seen + 1] = float_text()
      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      T.press("vf;h")
      vim.fn.maparg("<leader>cb", "x", false, true).callback()
      seen[#seen + 1] = float_text()
      seen[#seen + 1] = vim.fn.mode()
    end)
    reset_editor()
    expect(ok, tostring(err))
    expect(
      vim.deep_equal(seen, {
        "0x0C | dec  12 | hex  0xc | bin  0b0000_1100 | bit  3, 2 set (0=LSB)",
        "(1 << 4) | 1 | dec  17 | hex  0x11 | bin  0b0001_0001 | bit  4, 0 set (0=LSB)",
        "n",
      }),
      "by the key: " .. vim.inspect(seen)
    )
  end)
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

  -- The preview of a picker takes six tenths of the width, the list four, and
  -- <C-l> / <C-h> scroll it sideways by a quarter of its width: the halves it had cut
  -- a long line of C off in both, and snacks scrolled a column a press.
  check("picker: a wide preview, scrolled sideways by a quarter of its width", function()
    local dir = temp_dir()
    T.write(dir .. "/w.c", { "int a;", "    int a_rather_long_name = " .. ("0x1234, "):rep(30) .. "0;", "int b;" })
    local seen = {}
    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(dir)
      local picker = Snacks.picker.files({ pattern = "w.c:2" })
      local function preview_win()
        local win = picker.preview and picker.preview.win and picker.preview.win.win
        return win and vim.api.nvim_win_is_valid(win) and win or nil
      end
      vim.wait(3000, function()
        return preview_win() ~= nil and vim.api.nvim_win_get_cursor(preview_win())[1] == 2
      end, 20)
      local list, preview = picker.list.win.win, preview_win()
      -- Side by side only on a screen wide enough for it; a headless run is
      -- 80 columns, where the preview goes below the list instead.
      seen.widths = vim.o.columns < 120 or vim.api.nvim_win_get_width(list) < vim.api.nvim_win_get_width(preview)
      seen.preset = Snacks.config.picker.layout.preset()
      local function leftcol()
        return vim.api.nvim_win_call(preview, function()
          return vim.fn.winsaveview().leftcol
        end)
      end
      seen.before = leftcol()
      picker:action("preview_scroll_right")
      seen.right = leftcol()
      picker:action("preview_scroll_left")
      seen.back = leftcol()
      seen.step = math.floor(vim.api.nvim_win_get_width(preview) / 4)
      -- <C-Right> / <C-Left> give the preview more or less of the width,
      -- and a picker opened after starts at the share they left. On a narrow
      -- screen the preview stands below the list and has no width to give,
      -- so the share itself is what is checked, not the columns.
      local shares = _G.taka_picker_preview
      seen.share = { shares.share }
      picker:action("preview_wider")
      seen.share[#seen.share + 1] = shares.share
      picker:action("preview_narrower")
      picker:action("preview_narrower")
      seen.share[#seen.share + 1] = shares.share
      for _ = 1, 30 do
        picker:action("preview_narrower")
      end
      seen.share[#seen.share + 1] = shares.share
      for _ = 1, 30 do
        picker:action("preview_wider")
      end
      seen.share[#seen.share + 1] = shares.share
      -- Back to the share the config starts at, for the checks after.
      for _ = 1, 6 do
        picker:action("preview_narrower")
      end
      seen.share[#seen.share + 1] = shares.share
    end)
    for _, picker in ipairs(Snacks.picker.get({ source = "files" })) do
      picker:close()
    end
    reset_editor()
    expect(ok, tostring(err))
    expect(seen.widths, "the preview is not wider than the list")
    expect(
      seen.preset == (vim.o.columns >= 120 and "wide_preview" or "vertical"),
      "the layout chosen is " .. tostring(seen.preset)
    )
    expect(
      seen.before == 0 and seen.right == seen.step and seen.back == 0,
      ("scrolled %s -> %s -> %s, a step being %s"):format(seen.before, seen.right, seen.back, seen.step)
    )
    local shares = vim.tbl_map(function(v)
      return v and ("%.2f"):format(v) or "nil"
    end, seen.share or {})
    expect(
      table.concat(shares, " ") == "0.60 0.65 0.55 0.20 0.90 0.60",
      "the preview's share went " .. table.concat(shares, " ")
    )
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

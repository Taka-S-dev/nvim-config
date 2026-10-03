-- Comparing two windows (lua/taka/diff/).
return function(T)
  local check, expect, temp_dir, write, run, floats, press, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.run, T.floats, T.press, T.reset_editor

  -- Two files in diff mode, each with a strip of where they differ: a changed
  -- line, a line only on the right and one only on the left sit on the same
  -- rows of both strips, the part in view is lit and moves with the view, a
  -- click on a change lands on it, and the strips go with the diff.
  check("diff map: a strip shows where two files differ, and a click goes there", function()
    local map = require("taka.diff.map")
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
    local pane = require("taka.diff.pane")
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
    local pane = require("taka.diff.pane")
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
    local quit = require("taka.diff.quit")
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
      require("taka.diff").on_quit(vim.api.nvim_get_current_tabpage(), require("taka.svn").close_log)
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
    local follow = require("taka.diff.scroll").follow
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
end

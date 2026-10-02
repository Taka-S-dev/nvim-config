-- Who wrote each line, in which revision and when (<leader>vb), as
-- TortoiseSVN's blame shows it: a narrow window on the left of the file, a
-- row a line, kept level with it as either is scrolled. Shown only while it
-- is wanted; the same key or q in it closes it, and nothing is run before it
-- is asked for.
--
-- svn blame asks the repository, so it runs in the background, and its
-- answer is kept: opened again on an unchanged base, it shows at once without
-- running svn blame. The lines are those of the base (the last svn update),
-- so lines edited since are matched to it by a diff of the base against the
-- buffer: an edited or added line says (local), and the others keep their
-- revision however many lines were added above them. Enter on a row shows the
-- message of that revision.
local M = {}

local ns = vim.api.nvim_create_namespace("config_svn_blame")
-- The lines of the revision the cursor is on, marked in both windows.
local same = vim.api.nvim_create_namespace("config_svn_blame_same")

-- The rows of that revision take the colour a selection's other occurrences
-- are lit in (lua/config/selection_matches.lua): the same thing elsewhere,
-- and not the cursor line's. In the file only the line numbers are coloured,
-- so the code, a diff's colours and the cursor line are left as they are.
local function colours()
  vim.api.nvim_set_hl(0, "SvnBlameSame", { link = "LspReferenceText", default = true })
  vim.api.nvim_set_hl(0, "SvnBlameSameNr", { link = "DiagnosticInfo", default = true })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_svn_blame_colours", { clear = true }),
  callback = colours,
})

-- svn blame's answer per file, with the base it was for; and the blame shown
-- per window of a file.
local answers = {}
local open = {}

-- Keys that scroll the view. The cursor they drag along with it is no line
-- chosen, so the marking stays on the revision it was on.
local scroll_keys
local function scrolls(key)
  if not scroll_keys then
    scroll_keys = {}
    for _, name in ipairs({
      "<ScrollWheelUp>",
      "<ScrollWheelDown>",
      "<ScrollWheelLeft>",
      "<ScrollWheelRight>",
      "<C-e>",
      "<C-y>",
    }) do
      scroll_keys[vim.keycode(name)] = true
    end
  end
  return scroll_keys[key] == true
end

local function unescape(text)
  return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- `svn blame --xml`: the revision, author and day of each line of the base.
function M.parse(xml)
  local lines = {}
  for number, body in xml:gmatch('<entry%s+line%-number="(%d+)">(.-)</entry>') do
    lines[tonumber(number)] = {
      revision = tonumber(body:match('revision="(%d+)"')),
      author = unescape(body:match("<author>(.-)</author>") or "?"),
      day = body:match("<date>(%d%d%d%d%-%d%d%-%d%d)") or "",
    }
  end
  return lines
end

local function lines_of(text)
  local lines = vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

-- For each line of `current`, the line of `base` it is, or false where it was
-- edited or added since.
function M.match(base, current)
  local hunks = vim.diff(table.concat(base, "\n") .. "\n", table.concat(current, "\n") .. "\n", {
    result_type = "indices",
  })
  local map, from_base, line = {}, 1, 1
  for _, hunk in ipairs(hunks) do
    local base_start, base_count, start, count = unpack(hunk)
    -- A hunk that takes nothing names the line before it.
    local last_same = count == 0 and start or start - 1
    while line <= last_same do
      map[line], from_base, line = from_base, from_base + 1, line + 1
    end
    for _ = 1, count do
      map[line], line = false, line + 1
    end
    from_base = base_count == 0 and base_start + 1 or base_start + base_count
  end
  while line <= #current do
    map[line], from_base, line = from_base, from_base + 1, line + 1
  end
  return map
end

-- The rows of the blame window for a buffer: one a line, and whether each
-- repeats the revision of the row above, to be drawn faint.
function M.rows(answer, current)
  local map, out = M.match(answer.base, current), {}
  local previous
  for line = 1, #current do
    local entry = map[line] and answer.lines[map[line]]
    if not entry then
      out[line] = { text = "(local)", local_edit = true }
      previous = nil
    else
      out[line] = {
        text = ("r%-5d %-10s %s"):format(entry.revision, entry.author:sub(1, 10), entry.day),
        revision = entry.revision,
        repeated = previous == entry.revision,
      }
      previous = entry.revision
    end
  end
  return out
end

-- Set below, used by draw: the rows of the cursor's revision marked again.
local mark

local function draw(state)
  if not (vim.api.nvim_buf_is_valid(state.buf) and vim.api.nvim_buf_is_valid(state.blame_buf)) then
    return
  end
  -- No blame for the file in the window yet, or none to be had: one row says
  -- which, so that rows of another file are never shown beside it.
  if not state.answer then
    state.rows = { { text = state.note or "" } }
    vim.bo[state.blame_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.blame_buf, 0, -1, false, { state.rows[1].text })
    vim.bo[state.blame_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(state.blame_buf, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(state.blame_buf, same, 0, -1)
    vim.api.nvim_buf_set_extmark(state.blame_buf, ns, 0, 0, { end_col = #state.rows[1].text, hl_group = "Comment" })
    return
  end
  state.rows = M.rows(state.answer, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
  local texts = vim.tbl_map(function(row)
    return row.text
  end, state.rows)
  vim.bo[state.blame_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.blame_buf, 0, -1, false, texts)
  vim.bo[state.blame_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.blame_buf, ns, 0, -1)
  for index, row in ipairs(state.rows) do
    local group = (row.repeated or row.local_edit) and "Comment" or nil
    if group then
      vim.api.nvim_buf_set_extmark(state.blame_buf, ns, index - 1, 0, { end_col = #row.text, hl_group = group })
    elseif row.revision then
      local width = #("r" .. row.revision)
      vim.api.nvim_buf_set_extmark(state.blame_buf, ns, index - 1, 0, { end_col = width, hl_group = "Number" })
    end
  end
  if vim.api.nvim_win_is_valid(state.win) then
    mark(state, vim.api.nvim_win_get_cursor(state.win)[1])
  end
end

-- The rows of the revision on line `line` marked beside the file, and their
-- lines' numbers in it; none for a line edited since the update.
mark = function(state, line)
  for _, buf in ipairs({ state.blame_buf, state.buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, same, 0, -1)
    end
  end
  local revision = state.rows and state.rows[line] and state.rows[line].revision
  if not revision then
    return
  end
  for index, row in ipairs(state.rows) do
    if row.revision == revision then
      vim.api.nvim_buf_set_extmark(state.blame_buf, same, index - 1, 0, { line_hl_group = "SvnBlameSame" })
      if index <= vim.api.nvim_buf_line_count(state.buf) then
        vim.api.nvim_buf_set_extmark(state.buf, same, index - 1, 0, { number_hl_group = "SvnBlameSameNr" })
      end
    end
  end
end

-- The two windows kept level: the one that scrolled leads, as the wheel can
-- turn either while the cursor is in the other.
local function level(state, leader)
  local follower = leader == state.win and state.blame_win or state.win
  if not (vim.api.nvim_win_is_valid(leader) and vim.api.nvim_win_is_valid(follower)) then
    return
  end
  local top = vim.api.nvim_win_call(leader, vim.fn.winsaveview).topline
  vim.api.nvim_win_call(follower, function()
    if vim.fn.line("w0") ~= top then
      -- The cursor kept in view and 'scrolloff' lines inside it, or Vim
      -- scrolls the view back to the cursor.
      local margin = vim.wo.scrolloff >= 0 and vim.wo.scrolloff or vim.o.scrolloff
      local height = vim.api.nvim_win_get_height(0)
      margin = math.min(margin, math.floor((height - 1) / 2))
      local line = math.min(math.max(vim.fn.line("."), top + margin), top + height - 1 - margin)
      vim.fn.winrestview({ topline = top, lnum = math.max(1, math.min(line, vim.fn.line("$"))) })
    end
  end)
end

function M.close(win)
  local state = open[win]
  open[win] = nil
  if state and vim.api.nvim_win_is_valid(state.blame_win) then
    vim.api.nvim_win_close(state.blame_win, true)
  end
  if state and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].wrap = state.wrapped
    vim.w[win].svn_blame = nil
  end
  if state then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
    vim.on_key(nil, state.keys)
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, same, 0, -1)
    end
  end
end

local function show(win, answer)
  local buf = vim.api.nvim_win_get_buf(win)
  local blame_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[blame_buf].filetype = "svnblame"
  local blame_win = vim.api.nvim_open_win(blame_buf, false, { split = "left", win = win, width = 30 })
  for option, value in pairs({
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    foldenable = false,
    cursorline = true,
    scrolloff = 0,
    winfixwidth = true,
    list = false,
  }) do
    vim.wo[blame_win][option] = value
  end
  -- Rows line up with lines only while neither wraps; the file's own setting
  -- comes back when the blame is put away.
  local wrapped = vim.wo[win].wrap
  vim.wo[win].wrap = false
  local state = {
    wrapped = wrapped,
    win = win,
    buf = buf,
    blame_win = blame_win,
    blame_buf = blame_buf,
    answer = answer,
    group = vim.api.nvim_create_augroup("config_svn_blame_" .. win, { clear = true }),
  }
  open[win] = state
  -- Both windows jump to where they scroll, without smooth scrolling
  -- (lua/plugins/snacks-scroll.lua). Stepped, the one following trailed a
  -- step behind, and its own scroll pulled the other back: with the wheel
  -- turned over the file, the tops went 54, 52, 49, 43 and stopped two lines
  -- apart.
  vim.w[win].svn_blame, vim.w[blame_win].svn_blame = true, true
  draw(state)
  level(state, win)
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = state.group,
    callback = function()
      local scrolled = vim.v.event
      if scrolled[tostring(win)] then
        level(state, win)
      elseif scrolled[tostring(blame_win)] then
        level(state, blame_win)
      end
    end,
  })
  -- Whether the last key scrolled: the cursor moving with it leaves the
  -- marking where it was.
  state.keys = vim.api.nvim_create_namespace("config_svn_blame_keys_" .. win)
  vim.on_key(function(key, typed)
    state.scrolling = scrolls(typed ~= "" and typed or key)
  end, state.keys)
  -- The cursor of either window puts the other's on the same line: a row
  -- clicked or stepped to in the blame moves the file's cursor to its line,
  -- in the column it was in. Each side moves the other only from its own
  -- window, so neither moves the first back. Set by window, not by buffer:
  -- the file in the window can change.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.group,
    callback = function()
      local current = vim.api.nvim_get_current_win()
      if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(blame_win)) then
        return
      end
      if current == win then
        local line = math.min(vim.fn.line("."), vim.api.nvim_buf_line_count(blame_buf))
        vim.api.nvim_win_set_cursor(blame_win, { line, 0 })
        if not state.scrolling then
          mark(state, line)
        end
      elseif current == blame_win then
        local line = math.min(vim.fn.line("."), vim.api.nvim_buf_line_count(state.buf))
        vim.api.nvim_win_set_cursor(win, { line, vim.api.nvim_win_get_cursor(win)[2] })
        if not state.scrolling then
          mark(state, vim.fn.line("."))
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = state.group,
    callback = function(event)
      if event.buf == state.buf then
        draw(state)
      end
    end,
  })
  -- Another file in the window: the blame goes with the window, to that file.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = state.group,
    callback = function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) ~= state.buf then
        M.switch(state, vim.api.nvim_win_get_buf(win))
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.group,
    callback = function(event)
      local closed = tonumber(event.match)
      if closed == win or closed == blame_win then
        vim.schedule(function()
          M.close(win)
        end)
      end
    end,
  })
  vim.keymap.set("n", "q", function()
    M.close(win)
  end, { buffer = blame_buf, nowait = true, desc = "Close the blame" })
  vim.keymap.set("n", "<CR>", function()
    M.message(state.rows[vim.fn.line(".")])
  end, { buffer = blame_buf, desc = "The message of this revision" })
end

-- The message of the revision a row is from.
function M.message(row)
  if not (row and row.revision) then
    return
  end
  require("config.svn").run({ "log", "-r", tostring(row.revision), "--", M.file_of(row) }, function(result)
    vim.notify(vim.trim(result.stdout ~= "" and result.stdout or result.stderr), vim.log.levels.INFO, { title = "svn" })
  end)
end

-- The file the rows of the current blame window are of.
function M.file_of()
  for _, state in pairs(open) do
    if state.blame_win == vim.api.nvim_get_current_win() then
      return vim.api.nvim_buf_get_name(state.buf)
    end
  end
  return vim.api.nvim_buf_get_name(0)
end

-- The blame of a buffer's file, handed to `done`, or nil and why there is
-- none. The base is read from the working copy, which is quick; only when it
-- is not the one blamed before is the repository asked.
local function answer_for(buf, done)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" or vim.bo[buf].buftype ~= "" then
    return done(nil, "(no file)")
  end
  local svn = require("config.svn")
  svn.run({ "cat", "-r", "BASE", "--", file }, function(cat)
    if cat.code ~= 0 then
      return done(nil, "(not under svn)")
    end
    local base = lines_of(cat.stdout)
    local known = answers[file]
    if known and vim.deep_equal(known.base, base) then
      return done(known)
    end
    local answered = require("config.activity").begin("svn blame: " .. vim.fs.basename(file))
    svn.run({ "blame", "--xml", "-r", "BASE", "--", file }, function(result)
      if result.code ~= 0 then
        answered("failed")
        return done(nil, "(svn blame failed)")
      end
      answers[file] = { base = base, lines = M.parse(result.stdout) }
      answered(("%d lines"):format(#base))
      done(answers[file])
    end)
  end)
end

-- The window's file changed: the blame of the new one, a row saying it is
-- coming in the meantime.
function M.switch(state, buf)
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, same, 0, -1)
  end
  state.buf, state.answer, state.note = buf, nil, "…"
  draw(state)
  answer_for(buf, function(answer, why)
    if open[state.win] ~= state or state.buf ~= buf then
      return
    end
    state.answer, state.note = answer, why
    draw(state)
    level(state, state.win)
  end)
end

-- The blame of the window's file shown, or put away when it is shown.
function M.toggle(win)
  win = win or vim.api.nvim_get_current_win()
  for code_win, state in pairs(open) do
    if code_win == win or state.blame_win == win then
      return M.close(code_win)
    end
  end
  local buf = vim.api.nvim_win_get_buf(win)
  answer_for(buf, function(answer, why)
    if not answer then
      vim.notify("No blame here: " .. why, vim.log.levels.WARN, { title = "svn" })
    elseif vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and not open[win] then
      show(win, answer)
    end
  end)
end

-- For the checks: the rows shown beside a window, as text.
function M.lines(win)
  local state = open[win]
  return state and vim.api.nvim_buf_get_lines(state.blame_buf, 0, -1, false) or {}
end

-- For the checks: the lines marked as of the cursor's revision, beside the
-- file and in it, as "1,4,5".
function M.marked(win)
  local state = open[win]
  local function lines(buf)
    return table.concat(
      vim.tbl_map(function(mark)
        return mark[2] + 1
      end, vim.api.nvim_buf_get_extmarks(buf, same, 0, -1, {})),
      ","
    )
  end
  return state and (lines(state.blame_buf) .. " / " .. lines(state.buf)) or ""
end

function M.window(win)
  return open[win] and open[win].blame_win
end

-- For the checks, which see no WinScrolled: the other window brought level
-- with `win`, the file's or the blame's.
function M.follow(win)
  for _, state in pairs(open) do
    if state.win == win or state.blame_win == win then
      level(state, win)
    end
  end
end

return M

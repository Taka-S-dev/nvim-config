-- Subversion from inside the editor: what changed, what the history says, and
-- the difference any revision made. Everything here reads; nothing commits,
-- updates or reverts a file on disk. The one change it can make, putting a
-- hunk back to the base, goes through the buffer and asks first.
--
--   <leader>vs  svn status of the cwd, or from the file tree of the folder
--               selected, in the quickfix list
--   <leader>vS  svn status of a directory typed in
--   <leader>vd  the whole file against the base, side by side
--   <leader>vh  the log of the current file, or of the file or folder selected
--               in the file tree, in a tab of its own, as TortoiseSVN's log
--               window: Enter on a revision lists the files it changed, Enter
--               on a file shows that change side by side
--   <leader>vp  the change under the cursor;  <leader>vr  put it back, asking
--   ]h / [h     next / previous change (vim-signify, lua/plugins/svn.lua)
--
-- svn.exe has to be on the PATH; where it is not, none of these keys is
-- defined. Revisions are fetched by URL and peg revision, so a file that
-- was deleted or renamed since can still be shown.
local M = {}

local function say(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "svn" })
end

-- svn run in the background; `done` gets the result on the main loop, where
-- it may start the next svn: calling vim.system from the callback itself is
-- what raised E5560.
local function run(args, done)
  if vim.fn.executable("svn") ~= 1 then
    say("svn is not on the PATH", vim.log.levels.WARN)
    return
  end
  vim.system(vim.list_extend({ "svn", "--non-interactive" }, args), { text = true }, function(result)
    vim.schedule(function()
      done(result)
    end)
  end)
end

-- For lua/taka/svn/blame.lua, which runs svn the same way.
M.run = run

local function lines_of(text)
  local lines = vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function unescape(text)
  return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- The entry under the cursor in the file tree, when that is where the cursor is.
local function tree_selection()
  local ok, pickers = pcall(Snacks.picker.get, { source = "explorer" })
  for _, picker in ipairs(ok and pickers or {}) do
    if picker.list.win.win == vim.api.nvim_get_current_win() then
      local item = picker:current()
      if item and item.file then
        return vim.fs.normalize(item.file)
      end
    end
  end
end

-- The path to work on: the entry selected in the file tree, else the current
-- file, else the cwd.
local function target()
  local selected = tree_selection()
  if selected then
    return selected
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and vim.bo.buftype == "" then
    return vim.fs.normalize(name)
  end
  return vim.fs.normalize(vim.fn.getcwd())
end

local function scratch(lines, name, filetype)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

-- A heading over one side of a diff, naming what it shows, as each pane of
-- WinMerge is headed: pairs of text and highlight group. Text is taken as it
-- is, a % in a commit message included, not as a winbar item.
local function heading(win, parts)
  local out = {}
  for _, part in ipairs(parts) do
    local text = (part[1]:gsub("%%", "%%%%"))
    out[#out + 1] = part[2] and ("%#" .. part[2] .. "#" .. text .. "%*") or text
  end
  vim.wo[win].winbar = " " .. table.concat(out, "  ")
end

-- The order of the list, changes first and what is not versioned last, and
-- the colour of each state.
local STATES = {
  conflicted = { 1, "DiagnosticError" },
  modified = { 2, "Changed" },
  added = { 3, "Added" },
  replaced = { 4, "Changed" },
  deleted = { 5, "Removed" },
  missing = { 6, "DiagnosticWarn" },
  obstructed = { 7, "DiagnosticWarn" },
  unversioned = { 8, "Comment" },
  ignored = { 9, "Comment" },
}
local WIDTH = 13

-- Each line of the list as the state, in a column of its own, then the path
-- under the folder asked about: no line number, since there is none to give.
function M.status_text(info)
  local list = vim.fn.getqflist({ id = info.id, items = 1, context = 1 })
  local dir = type(list.context) == "table" and list.context.svn_status or ""
  -- bufname() is relative to the cwd when it can be, so it is made full first;
  -- Windows paths compare without case, the drive letter above all.
  local fold = vim.fn.has("win32") == 1 and string.lower or function(s)
    return s
  end
  local lines = {}
  for index = info.start_idx, info.end_idx do
    local item = list.items[index]
    local path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.bufname(item.bufnr), ":p"))
    if dir ~= "" and fold(path:sub(1, #dir + 1)) == fold(dir .. "/") then
      path = path:sub(#dir + 2)
    end
    lines[#lines + 1] = ("%-" .. WIDTH .. "s%s"):format(item.text, path)
  end
  return lines
end

-- The quickfix syntax takes a line with no | for a file name as a whole, and
-- is loaded again whenever the list is shown, so the states are coloured on
-- top of it each time.
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("config_svn_status", { clear = true }),
  pattern = "qf",
  callback = function(event)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(event.buf) then
        return
      end
      local context = vim.fn.getqflist({ context = 1 }).context
      if type(context) ~= "table" or not context.svn_status then
        return
      end
      vim.api.nvim_buf_call(event.buf, function()
        for state, look in pairs(STATES) do
          vim.cmd(("syntax match svnStatus_%s /^%s\\>/"):format(state, state))
          vim.cmd(("highlight default link svnStatus_%s %s"):format(state, look[2]))
        end
      end)
    end)
  end,
})

function M.status(dir)
  dir = vim.fs.normalize(dir or vim.fn.getcwd())
  if vim.fn.isdirectory(dir) ~= 1 then
    dir = vim.fs.dirname(dir)
  end
  run({ "status", "--xml", "--", dir }, function(result)
    if result.code ~= 0 then
      say("svn status failed in " .. dir .. ":\n" .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
      return
    end
    local items = {}
    for path, body in (result.stdout or ""):gmatch('<entry%s+path="([^"]*)">(.-)</entry>') do
      path = vim.fs.normalize(unescape(path))
      local state = body:match('<wc%-status[^>]-item="([%w%-]+)"') or "?"
      -- Unversioned dot files and dot folders are tool state (.vs, .cache,
      -- .idea), never meant to be added; versioned ones still show.
      local hidden = (state == "unversioned" or state == "ignored") and path:find("/%.[^/]") ~= nil
      if not hidden then
        items[#items + 1] = { filename = path, text = state }
      end
    end
    table.sort(items, function(a, b)
      local ra, rb = (STATES[a.text] or { 7 })[1], (STATES[b.text] or { 7 })[1]
      if ra ~= rb then
        return ra < rb
      end
      return a.filename < b.filename
    end)
    vim.fn.setqflist({}, " ", {
      title = "SVN status: " .. dir,
      items = items,
      context = { svn_status = dir },
      quickfixtextfunc = "v:lua.require'taka.svn'.status_text",
    })
    if #items == 0 then
      say("No changes under " .. dir)
      return
    end
    vim.cmd("botright copen")
  end)
end

-- From the file tree, the folder selected, or the folder of the file selected;
-- anywhere else, the cwd.
function M.status_here()
  M.status(tree_selection())
end

function M.status_of_choice()
  local start = target()
  if vim.fn.isdirectory(start) ~= 1 then
    start = vim.fs.dirname(start)
  end
  vim.ui.input({ prompt = "SVN status of: ", default = start, completion = "dir" }, function(dir)
    if dir and dir ~= "" then
      M.status(dir)
    end
  end)
end

function M.diff_file()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    say("This buffer has no file", vim.log.levels.WARN)
    return
  end
  local win, filetype = vim.api.nvim_get_current_win(), vim.bo.filetype
  run({ "cat", "-r", "BASE", "--", file }, function(result)
    if result.code ~= 0 then
      say("No base to compare with: " .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
      return
    end
    local name = vim.fs.basename(file)
    vim.api.nvim_set_current_win(win)
    vim.cmd("diffthis")
    heading(win, { { "working copy", "Number" }, { name }, { "(the file as edited)", "Comment" } })
    vim.cmd("leftabove vnew")
    local base = scratch(lines_of(result.stdout), "BASE:" .. name, filetype)
    vim.cmd("diffthis")
    heading(0, { { "BASE", "Number" }, { name }, { "(as of the last svn update)", "Comment" } })
    -- The file's own window outlives the comparison; its heading goes with it.
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = base,
      once = true,
      callback = function()
        if vim.api.nvim_win_is_valid(win) then
          vim.wo[win].winbar = ""
        end
      end,
    })
    vim.api.nvim_set_current_win(win)
  end)
end

-- %XX in a URL back to the byte, as the log writes paths.
local function decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- Where a path is in the repository: the root of the repository and the path
-- inside it, which is how the log names what a revision changed.
local function where(path, done)
  run({ "info", "--xml", "--", path }, function(result)
    local xml = result.stdout or ""
    local url, root = xml:match("<url>(.-)</url>"), xml:match("<root>(.-)</root>")
    if result.code ~= 0 or not url or not root then
      say("Not in a Subversion working copy: " .. path, vim.log.levels.WARN)
      return
    end
    url, root = unescape(url), unescape(root)
    done(url, root, decode(url:sub(#root + 1)))
  end)
end

-- Each revision with its message, a line at a time, and the files it changed
-- anywhere in the repository. The XML breaks the line between <logentry and
-- revision=, and wraps the paths in <paths>, hence <path%s.
local function parse_log(xml)
  local entries = {}
  for rev, body in xml:gmatch('<logentry%s+revision="(%d+)">(.-)</logentry>') do
    local message = unescape(body:match("<msg>(.-)</msg>") or ""):gsub("\r\n", "\n")
    local files = {}
    for attributes, path in body:gmatch("<path%s([^>]*)>(.-)</path>") do
      if attributes:match('kind="([^"]*)"') ~= "dir" then
        files[#files + 1] = { action = attributes:match('action="(%a)"') or "?", path = unescape(path) }
      end
    end
    table.sort(files, function(a, b)
      return a.path < b.path
    end)
    entries[#entries + 1] = {
      rev = tonumber(rev),
      author = unescape(body:match("<author>(.-)</author>") or ""),
      date = (body:match("<date>(.-)</date>") or ""):sub(1, 10),
      message = vim.split(vim.trim(message), "\n", { plain = true }),
      files = files,
    }
  end
  return entries
end

local ACTIONS = { A = "Added", M = "Changed", R = "Changed", D = "Removed" }

-- The rows of the log: each revision, and under an open one the rest of its
-- message and the files it changed. A file under the folder the log was asked
-- for is named from there; one elsewhere keeps its path in the repository and
-- is dimmed, as TortoiseSVN shows it. `parent` keeps a matching row's revision
-- in sight while a filter is typed, `sort` keeps the rows in this order.
local function log_rows(state, filtering)
  local items = {}
  local function add(item)
    item.sort = ("%06d"):format(#items + 1)
    items[#items + 1] = item
    return item
  end
  for _, entry in ipairs(state.entries) do
    local text = ("r%d %s %s %s"):format(entry.rev, entry.author, entry.date, table.concat(entry.message, " "))
    local row = add({ kind = "rev", entry = entry, text = text })
    if state.opened[entry.rev] or filtering then
      local children = {}
      for index = 2, #entry.message do
        if vim.trim(entry.message[index]) ~= "" then
          children[#children + 1] = { kind = "message", line = entry.message[index] }
        end
      end
      for _, file in ipairs(entry.files) do
        local inside = state.base == "" or file.path:sub(1, #state.base + 1) == state.base .. "/"
        children[#children + 1] = {
          kind = "file",
          file_path = file.path,
          action = file.action,
          inside = inside,
          name = inside and file.path:sub(#state.base + 2) or file.path,
        }
      end
      for index, child in ipairs(children) do
        child.entry, child.parent, child.last = entry, row, index == #children
        child.text = text .. " " .. (child.name or child.line)
        add(child)
      end
    end
  end
  return items
end

local function log_row_text(state, item)
  if item.kind == "rev" then
    return {
      { state.opened[item.entry.rev] and "- " or "+ " },
      { ("r%-5d"):format(item.entry.rev), "Number" },
      { item.entry.date .. " ", "Comment" },
      { item.entry.author .. "  ", "Identifier" },
      { item.entry.message[1] or "" },
    }
  end
  local guide = { item.last and state.look.last or state.look.middle, "SnacksPickerTree" }
  if item.kind == "message" then
    return { guide, { item.line, "Comment" } }
  end
  -- The file name first and its folder after it, dimmed: in a list this
  -- narrow a long path ran the name off the edge, and the name is what is
  -- looked for.
  local folder = vim.fs.dirname(item.name)
  local row = {
    guide,
    { item.action .. " ", ACTIONS[item.action] or "Comment" },
    { vim.fs.basename(item.name), not item.inside and "Comment" or nil },
  }
  if folder ~= "." and folder ~= "" then
    row[#row + 1] = { "  " .. folder, "Comment" }
  end
  return row
end

-- A file as a revision left it, side by side with the revision before, in the
-- log's own tab left of the list; the next file chosen takes its place. A side
-- the file did not exist on, added or deleted in that revision, is empty.
local function show_change(state, item)
  local rev, url = item.entry.rev, state.root .. item.file_path
  local name = vim.fs.basename(item.file_path)
  local filetype = vim.filetype.match({ filename = name })
  local function cat(at, done)
    run({ "cat", "--", url .. "@" .. at }, function(result)
      done(result.code == 0 and lines_of(result.stdout) or {})
    end)
  end
  cat(rev - 1, function(old)
    cat(rev, function(new)
      if not vim.api.nvim_tabpage_is_valid(state.tab) or state.picker.closed then
        return
      end
      if state.right and vim.api.nvim_win_is_valid(state.right) then
        vim.api.nvim_win_close(state.right, true)
      end
      if state.left and vim.api.nvim_win_is_valid(state.left) then
        vim.api.nvim_set_current_win(state.left)
        vim.cmd("enew")
      else
        vim.api.nvim_set_current_win(state.picker.list.win.win)
        vim.cmd("topleft vnew")
        state.left = vim.api.nvim_get_current_win()
      end
      scratch(old, ("r%d:%s"):format(rev - 1, name), filetype)
      vim.cmd("diffthis")
      heading(0, {
        { ("r%d"):format(rev - 1), "Number" },
        { item.file_path },
        { ("(before r%d)"):format(rev), "Comment" },
      })
      vim.cmd("rightbelow vnew")
      state.right = vim.api.nvim_get_current_win()
      scratch(new, ("r%d:%s"):format(rev, name), filetype)
      vim.cmd("diffthis")
      heading(0, {
        { ("r%d"):format(rev), "Number" },
        { item.file_path },
        { item.entry.author, "Identifier" },
        { item.entry.date, "Comment" },
        { item.entry.message[1] or "" },
      })
      -- To the first change, which in a long file is rarely on the first page.
      vim.cmd("normal! gg")
      if vim.fn.diff_hlID(1, 1) == 0 then
        pcall(vim.cmd, "normal! ]c")
      end
      state.picker:focus("list")
    end)
  end)
end

-- The log's tab closed, the list, the sides and the pane with it. Its sides
-- are scratch copies of revisions with nothing to save, but :tabclose, even
-- with !, refused one it took for changed (E445), so the windows are closed
-- one by one and the last takes the tab. The only tab is left open.
function M.close_log(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) or #vim.api.nvim_list_tabpages() < 2 then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_tabpage_is_valid(tab) and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

-- The log of the current file, or of the file or folder selected in the file
-- tree, in a tab of its own: the revisions in a list on the right, the change
-- to a file on the left. Enter, l or a double click on a revision lists the
-- files it changed, h folds it again; Enter or a double click on a file shows
-- what that revision did to it. Closing the list closes the tab.
function M.history(path)
  path = path or target()
  where(path, function(url, root, repo_path)
    run({ "log", "--xml", "-v", "-l", "100", "--", url }, function(result)
      if result.code ~= 0 then
        say("svn log failed: " .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
        return
      end
      local entries = parse_log(result.stdout or "")
      if #entries == 0 then
        say("No history for " .. path)
        return
      end
      local tree = {}
      pcall(function()
        tree = Snacks.picker.config.get().icons.tree
      end)
      local state = {
        entries = entries,
        root = root,
        base = vim.fn.isdirectory(path) == 1 and repo_path or vim.fs.dirname(repo_path),
        opened = {},
        look = { middle = tree.middle or "├╴", last = tree.last or "└╴" },
      }
      if state.base == "/" then
        state.base = ""
      end
      vim.cmd("tabnew")
      state.tab, state.left = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
      -- q anywhere in the tab closes it (lua/taka/diff/quit.lua).
      require("taka.diff").on_quit(state.tab, M.close_log)
      scratch({
        "",
        "  Enter on a revision lists the files it changed.",
        "  Enter on a file shows here what that revision did to it.",
        "  q in the list closes this tab.",
      }, "SVN log")
      local searching = false
      -- Open, close or, with nil, flip the revision of a row, the cursor
      -- staying on that revision.
      local function fold(picker, item, open)
        if item and item.kind ~= "rev" then
          item = item.parent
        end
        if not item then
          return
        end
        if open == nil then
          open = not state.opened[item.entry.rev]
        end
        state.opened[item.entry.rev] = open or nil
        picker:find({
          on_done = function()
            for index, row in ipairs(picker.list.items) do
              if row.kind == "rev" and row.entry == item.entry then
                picker.list:view(index)
              end
            end
          end,
        })
      end
      state.picker = Snacks.picker({
        source = "svn_log",
        title = "SVN log: " .. vim.fs.basename(path),
        finder = function(_, ctx)
          local filtering = not ctx.filter:is_empty()
          ctx.picker.matcher.opts.keep_parents = filtering
          return log_rows(state, filtering)
        end,
        format = function(item)
          return log_row_text(state, item)
        end,
        filter = {
          transform = function(_, filter)
            local now = not filter:is_empty()
            if searching ~= now then
              searching = now
              return true
            end
          end,
        },
        matcher = { sort_empty = false, fuzzy = false },
        sort = { fields = { "sort" } },
        focus = "list",
        auto_close = false,
        jump = { close = false },
        layout = { preset = "sidebar", preview = false, layout = { position = "right", width = 50 } },
        on_close = function()
          M.close_log(state.tab)
        end,
        confirm = function(picker, item)
          if item and item.kind == "file" then
            show_change(state, item)
          elseif item and item.kind == "rev" then
            fold(picker, item)
          end
        end,
        actions = {
          log_open = function(picker, item)
            fold(picker, item, true)
          end,
          log_close = function(picker, item)
            fold(picker, item, false)
          end,
        },
        win = {
          list = {
            keys = {
              ["<2-LeftMouse>"] = "confirm",
              ["l"] = "log_open",
              ["h"] = "log_close",
            },
          },
        },
      })
    end)
  end)
end

function M.undo_hunk()
  if vim.fn.confirm("Put the change under the cursor back to the base?", "&Yes\n&No", 2) == 1 then
    vim.cmd("SignifyHunkUndo")
  end
end

-- Who wrote each line of the window's file, beside it, or put away (blame.lua).
function M.blame()
  require("taka.svn.blame").toggle()
end

return M

-- Debug lines put into the code for a run (<leader>di and friends, :h
-- cfg-debug-lines): a printf or any line, each ending in a comment that marks
-- it, `/* DBG:group */`, and found again by that mark alone. No line number
-- is recorded, so a line moved by an edit above it, a restart of the editor
-- or an edit made elsewhere leaves nothing to go stale: what the files hold
-- is the list. Only the names of the files with lines in are kept, so that a
-- large tree is not searched through each time.
--
-- A line put in by an agent is marked `DBG-AI` instead, from the command line
-- (M.cli), and an agent can take away only those: the lines put in by hand
-- are left alone. The lines are written through the editor so a Shift-JIS
-- file is written back in Shift-JIS ('fileencodings', lua/config/options.lua).
local M = {}

-- The group given to the lines put in by hand outside any project, which is
-- also shown in their output; nil for none. In a project the group is kept
-- with it (group_of), so it stays after a restart.
M.group = nil

local GROUP = "^[%w_.%-]+$"

-- What ripgrep looks for: the mark at the end of a line, in a /* */ comment
-- or after //, -- or #, its number optional (a mark typed by hand may have
-- none). M.parse reads each line found again.
local MARK = [[DBG(-AI)?(:[\w.-]+)?(\s+#\d+)?]]
-- A /* */ mark may stand before the backslash that continues a macro.
local PATTERN = ([[(/\*\s*%s\s*\*/(\s*\\)?|(//|--|#)\s*%s)\s*$]]):format(MARK, MARK)

-- The lines offered for a language. `{tag}` stands for `DBG 12 group` (or
-- `DBG-AI 12 group`), which the output then shows: the number is the line's
-- own in the project, so the text printed, searched for, leads to the line it
-- came from however far the lines have moved since the run. `{n}` is the
-- number alone, and `{where}` the file and line put in at, for a language
-- that has no __LINE__. stderr in C, as it is not buffered and a line printed
-- just before a crash is not lost.
M.templates = {
  c = {
    [[fprintf(stderr, "[{tag}] %s:%d\n", __FILE__, __LINE__);]],
    [[printf("[{tag}] %s:%d\n", __FILE__, __LINE__);]],
  },
  go = { [[println("[{tag}] {where}")]] },
  lua = { [[print("[{tag}] {where}")]] },
  python = { [[print("[{tag}] {where}")]] },
}
M.templates.cpp = M.templates.c

-- The comment the mark is written in. C and C++ take /* */ whatever their
-- 'commentstring' says (it is //), since an older C compiler may not take //.
local function comment(filetype)
  if filetype == "c" or filetype == "cpp" then
    return "/* %s */"
  end
  local ok, form = pcall(vim.filetype.get_option, filetype, "commentstring")
  return ok and type(form) == "string" and form:find("%%s") and form or "/* %s */"
end

local function filetype_of(file)
  return vim.filetype.match({ filename = file }) or ""
end

-- The mark at the end of a line, `DBG-AI:group #12`.
local function mark_of(ai, group, n)
  local text = (ai and "DBG-AI" or "DBG") .. (group and group ~= "" and (":" .. group) or "")
  return n and (text .. " #" .. n) or text
end

-- The tag printed, `DBG-AI 12 group`, which is what a log is searched for.
-- The number comes first, where it stands whether there is a group or not,
-- so it is read at the same place down a log; the group, the same on most
-- lines of a run, comes after.
local function tag_of(ai, group, n)
  local text = (ai and "DBG-AI" or "DBG") .. (n and (" " .. n) or "")
  return text .. (group and group ~= "" and (" " .. group) or "")
end

-- The mark of a line: whether an agent put it in, its group ("" for none) and
-- its number (nil for none), or nil when the line is not a debug line.
function M.parse(line)
  local body = line:gsub("%s+$", "")
  local mark = body:match("/%*%s*(DBG[%w_.:%-]*%s*#?%d*)%s*%*/%s*\\?$")
  for _, opener in ipairs({ "//", "%-%-", "#" }) do
    mark = mark or body:match(opener .. "%s*(DBG[%w_.:%-]*%s*#?%d*)$")
  end
  if not mark then
    return nil
  end
  mark = vim.trim(mark)
  local name, n = mark:match("^(%S+)%s+#(%d+)$")
  if not name then
    name = mark
    if not name:match("^%S+$") then
      return nil
    end
  end
  local ai = name:find("^DBG%-AI") ~= nil
  local rest = name:gsub(ai and "^DBG%-AI" or "^DBG", "")
  if rest ~= "" and not rest:match("^:[%w_.%-]+$") then
    return nil
  end
  return { ai = ai, group = rest:sub(2), n = tonumber(n) }
end

-- The indent of a line put in after line `row` of `lines`: that of the line
-- below when `row` opens a block, else that of `row` itself. A blank `row`
-- has no indent to give: the line below gives it, as the new line goes
-- before that one, unless it closes a block, when the last line with text
-- above does (a printf put in after a blank line inside a block went to the
-- first column).
local function next_text(lines, from)
  for i = from, #lines do
    if lines[i]:find("%S") then
      return lines[i]
    end
  end
end

local function indent_after(lines, row)
  if row > 0 and not (lines[row] or ""):find("%S") then
    local below = next_text(lines, row + 1)
    if below and not below:match("^%s*}") then
      return below:match("^%s*")
    end
    while row > 0 and not (lines[row] or ""):find("%S") do
      row = row - 1
    end
  end
  local here = lines[row] or ""
  local lead = here:match("^%s*")
  if not here:match("{%s*$") then
    return lead
  end
  for i = row + 1, #lines do
    if lines[i]:find("%S") then
      if not lines[i]:match("^%s*}") then
        return lines[i]:match("^%s*")
      end
      break
    end
  end
  return lead .. ((lead:find("\t") or lead == "" and not vim.o.expandtab) and "\t" or string.rep(" ", 4))
end

-- The lines `text` becomes, put in after line `row` of a file: the template
-- filled in, the indent of the place, and the mark at the end of each line.
-- The lines of a block share their number, and go out together.
--
-- A line put in among the lines of a macro, after one ending in a backslash,
-- ends in one too, so the macro goes on past it and past where it was once
-- it is taken out; `continued` says so when the line above does not tell
-- (false for lines marked where they stand). A line that ends in a backslash
-- has its /* */ mark put before it: after it, the backslash would continue
-- nothing. A // comment there would swallow the backslash, so a line of a
-- language marked with one keeps its mark at the end.
local function build(text, file, filetype, row, lines, ai, group, n, continued)
  local fill = {
    tag = tag_of(ai, group, n),
    n = tostring(n),
    where = vim.fs.basename(file) .. ":" .. (row + 1),
  }
  local lead = indent_after(lines, row)
  local mark = comment(filetype):format(mark_of(ai, group, n))
  local block = mark:sub(-2) == "*/"
  if continued == nil then
    continued = (lines[row] or ""):match("\\%s*$") ~= nil
  end
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    -- A function, so a % in the name of a file is not read as a capture.
    line = line:gsub("{(%a+)}", function(key)
      return fill[key]
    end)
    line = line:gsub("%s+$", "")
    local own = block and line:match("^(.-)%s*\\$")
    local tail = (own or continued and block) and " \\" or ""
    -- A block of several lines keeps its own indent inside the place's.
    out[#out + 1] = lead .. (own or line) .. " " .. mark .. tail
  end
  return out
end

-- A path as compared with another: on Windows, case does not count.
local function same(path)
  path = vim.fs.normalize(path)
  return vim.fn.has("win32") == 1 and path:lower() or path
end

-- The debug lines among `lines`, as { lnum, text, ai, group, n }.
local function in_lines(lines)
  local found = {}
  for lnum, line in ipairs(lines) do
    local mark = M.parse(line)
    if mark then
      found[#found + 1] = { lnum = lnum, text = vim.trim(line), ai = mark.ai, group = mark.group, n = mark.n }
    end
  end
  return found
end

-- The debug lines of a file on disk, or nil when it cannot be read. Read as
-- bytes: the mark is ASCII in any encoding the file is in.
local function in_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a")
  handle:close()
  local lines = vim.split((data:gsub("\r\n", "\n")), "\n", { plain = true })
  return in_lines((require("taka.lib.legacy_text").lines(lines)))
end

-- The root to look in: the project the file is in, by GTAGS or version
-- control, else the one the working directory is in; nil outside any. The
-- working directory itself is not taken: started from the home folder, the
-- search went through all of it and the list took long to come.
local function root_of(buf)
  local root = require("taka.lib.gtags_global").root
  local markers = { ".git", ".svn" }
  return root(vim.api.nvim_buf_get_name(buf), markers) or root(vim.fn.getcwd() .. "/.", markers)
end

-- The files of a project known to hold debug lines, kept beside the editor's
-- data (not in the project). Only where to look is kept, never a line: each
-- file is read for its marks every time, so a file that has lost its lines
-- costs one read, and only a line marked by hand in a file not known is not
-- seen until every file is searched (<leader>dL).
-- The folder they are kept in; the tests put it elsewhere.
M.store = vim.env.DEBUG_LINES_STORE or vim.fs.joinpath(vim.fn.stdpath("data"), "debug_lines")

local function store_path(root)
  local dir = M.store
  vim.fn.mkdir(dir, "p")
  return vim.fs.joinpath(dir, vim.fn.sha256(same(root)):sub(1, 16) .. ".json")
end

-- What is kept for a project: the files, and the number the next line takes.
local function stored(root)
  local handle = io.open(store_path(root), "r")
  local data = {}
  if handle then
    local ok, read = pcall(vim.json.decode, handle:read("*a"))
    handle:close()
    data = ok and type(read) == "table" and read or {}
  end
  return {
    files = type(data.files) == "table" and data.files or {},
    next = type(data.next) == "number" and data.next or 1,
    typed = type(data.typed) == "table" and data.typed or {},
    group = type(data.group) == "string" and data.group or nil,
  }
end

local function write_store(root, data)
  table.sort(data.files)
  local handle = assert(io.open(store_path(root), "w"))
  local typed = next(data.typed) and data.typed or vim.empty_dict()
  handle:write(
    vim.json.encode({ root = root, files = data.files, next = data.next, typed = typed, group = data.group })
  )
  handle:close()
end

local function known(root)
  return stored(root).files
end

-- The files known are those given; the next number stays as it is.
local function keep(root, files)
  local data = stored(root)
  table.sort(files)
  table.sort(data.files)
  -- Written only when it changes: the count in the statusline reads the
  -- files on every buffer entered.
  if not vim.deep_equal(data.files, files) then
    data.files = files
    write_store(root, data)
  end
end

-- The count of debug lines left in the project of the current buffer, in the
-- statusline (lua/plugins/lualine-debug-lines.lua) as `DBG 3`, so lines not
-- taken out are seen before a commit, with the group lines go into now,
-- `DBG 3 · path-A`, as that group was set out of sight; nil, and nothing
-- shown, for no lines and no group. Set from every search of that project.
local function show_count(root, items)
  local here = root_of(0)
  if not here or same(here) ~= same(root) then
    return
  end
  local count = #M.blocks(items)
  local group = stored(root).group
  local text = (count > 0 or group) and ("DBG %d"):format(count) .. (group and (" · " .. group) or "") or nil
  if vim.g.debug_lines_count ~= text then
    vim.g.debug_lines_count = text
    vim.cmd.redrawstatus()
  end
end

-- The group lines put in by hand go into: the project's, else the one set
-- outside any project.
local function group_of(root)
  return root and stored(root).group or M.group
end

-- The number of a line about to be put in: the next of the project, and past
-- every number in `lines` (the file it goes in), so a project whose record
-- was lost does not give a number that file already has. Numbers are never
-- given twice, even after their lines are taken out, so a log of an earlier
-- run cannot lead to a line put in since.
-- With `peek`, the number is only looked at, for a preview, and not taken.
local function take_number(root, lines, peek)
  local data = root and stored(root) or { files = {}, next = 1 }
  local n = data.next
  for _, line in ipairs(lines) do
    local mark = M.parse(line)
    if mark and mark.n and mark.n >= n then
      n = mark.n + 1
    end
  end
  if root and not peek then
    data.next = n + 1
    write_store(root, data)
  end
  return n
end

-- Adds a file to those known to hold debug lines.
local function remember(root, file)
  if not root then
    return
  end
  local files, path = known(root), vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
  for _, seen in ipairs(files) do
    if same(seen) == same(path) then
      return
    end
  end
  files[#files + 1] = path
  keep(root, files)
end

-- The debug lines under `root`, handed to `done` as quickfix items with `ai`
-- and `group`, sorted by file and line: in the files known to hold some and
-- the files open, or with `everywhere` in every file, by ripgrep. A file open
-- in the editor is read from its buffer, so a line put in and not yet written
-- is there too. The files found with lines are then the ones known: one that
-- has none left, or is gone, is let go of.
function M.find(root, done, everywhere)
  root = vim.fs.normalize(root)
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and name ~= "" then
      if same(name):sub(1, #root + 1) == same(root) .. "/" then
        buffers[same(name)] = { name = name, found = in_lines(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) }
      end
    end
  end
  local function finish(on_disk)
    local items, files = {}, {}
    for _, file in pairs(vim.tbl_extend("force", on_disk, buffers)) do
      if #file.found > 0 then
        files[#files + 1] = file.name
      end
      for _, hit in ipairs(file.found) do
        hit.filename = file.name
        items[#items + 1] = hit
      end
    end
    keep(root, files)
    table.sort(items, function(a, b)
      if a.filename ~= b.filename then
        return a.filename < b.filename
      end
      return a.lnum < b.lnum
    end)
    show_count(root, items)
    done(items)
  end
  if not everywhere then
    local on_disk = {}
    for _, file in ipairs(known(root)) do
      local found = not buffers[same(file)] and in_file(file)
      if found then
        on_disk[same(file)] = { name = file, found = found }
      end
    end
    return finish(on_disk)
  end
  -- Not in text and Markdown: a help that shows a debug line as an example
  -- would lose it to <leader>dx.
  local rg = { "rg", "--crlf", "--line-number", "--with-filename", "--no-heading", "--color=never" }
  vim.list_extend(rg, { "--glob=!*.txt", "--glob=!*.md", "-e", PATTERN, root })
  vim.system(
    rg,
    { text = true },
    vim.schedule_wrap(function(result)
      local on_disk = {}
      for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
        file = file and vim.fs.normalize(file)
        local mark = file and M.parse(text)
        if mark then
          on_disk[same(file)] = on_disk[same(file)] or { name = file, found = {} }
          table.insert(on_disk[same(file)].found, {
            lnum = tonumber(lnum),
            text = vim.trim((require("taka.lib.legacy_text").text(text))),
            ai = mark.ai,
            group = mark.group,
            n = mark.n,
          })
        end
      end
      finish(on_disk)
    end)
  )
end

-- Another editor with `file` open, by the swap file it keeps: whether it
-- holds changes not written, and its process; nil when none has it open.
-- The swap file is looked for by the name Neovim gives it, the full path with
-- each separator and colon made a %: swapfilelist() names the files of a
-- swap folder wrongly on Windows (the folder twice over), and SwapExists does
-- not fire for bufload().
local function other_editor(file)
  local dir = vim.split(vim.o.directory, ",", { plain = true })[1]:gsub("[/\\]+$", "")
  dir = vim.fn.fnamemodify(dir, ":p")
  local prefix = same((vim.fn.fnamemodify(file, ":p"):gsub("[:/\\]", "%%")))
  local ok, entries = pcall(vim.fs.dir, dir)
  if not ok or not entries then
    return nil
  end
  for name in entries do
    if same(name):sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^%.sw.$") then
      local info = vim.fn.swapinfo(vim.fs.joinpath(dir, name))
      if info.pid and info.pid ~= vim.fn.getpid() then
        return { dirty = info.dirty == 1, pid = info.pid }
      end
    end
  end
end

-- A file's buffer to change, loaded without autocommands when it is not open:
-- no filetype, no language server, no formatter, only the file as it is read
-- ('fileencodings' and 'fileformats' are not autocommands).
local function load(file)
  local full = same(vim.fn.fnamemodify(file, ":p"))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and same(vim.api.nvim_buf_get_name(buf)) == full then
      return buf, false
    end
  end
  -- Read with no swap file of its own: none is needed for a moment, and
  -- finding another editor's, Neovim would print a page about it.
  local other = other_editor(file)
  local buf = vim.fn.bufadd(file)
  vim.bo[buf].swapfile = false
  local ignore = vim.o.eventignore
  vim.o.eventignore = "all"
  pcall(vim.fn.bufload, buf)
  vim.o.eventignore = ignore
  return buf, true, other
end

-- Why a file cannot be written now: open with changes not written in another
-- editor, which would either lose the debug lines when it writes, or find the
-- file changed under it.
local function held(other)
  return other and other.dirty and ("it has changes not written in another editor (process %d)"):format(other.pid)
end

-- Writes a buffer back as it was read. Without autocommands: a format on
-- save would rewrite the whole file. A file loaded here keeps a last line
-- with no newline after it.
local function save(buf, loaded_here)
  if loaded_here then
    vim.bo[buf].fixendofline = false
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("noautocmd silent write")
  end)
end

-- Whether every change of a buffer not yet written is in debug lines: the
-- buffer and its file on disk, each without them, are the same. Such a buffer
-- is written by the debug line keys, so a run built straight after sees the
-- lines; one with a change of the reader's own is not, as that is the
-- reader's to write. The file is read in the encoding the buffer has.
local function only_debug_changes(buf)
  if not vim.bo[buf].modified then
    return true
  end
  local handle = io.open(vim.api.nvim_buf_get_name(buf), "rb")
  if not handle then
    return false
  end
  local data = handle:read("*a")
  handle:close()
  local encoding = vim.bo[buf].fileencoding
  if encoding ~= "" and encoding ~= "utf-8" then
    data = vim.iconv(data, encoding, "utf-8") or data
  end
  local function code(lines)
    return vim.tbl_filter(function(line)
      return not M.parse(line)
    end, lines)
  end
  local on_disk = vim.split((data:gsub("\r\n", "\n"):gsub("\n$", "")), "\n", { plain = true })
  return vim.deep_equal(code(on_disk), code(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
end

-- Writes a buffer the debug line keys changed, when that is all that changed;
-- returns whether it was written.
local function save_if_only_debug(buf, loaded_here)
  if vim.api.nvim_buf_get_name(buf) == "" or not only_debug_changes(buf) then
    return false
  end
  save(buf, loaded_here)
  return true
end

-- Takes the debug lines for which `wanted(mark, lnum)` holds out of `files`, and
-- writes each file back. A file open with changes not yet written loses the
-- lines in its buffer and is not written, so the changes stay the reader's to
-- write. A file open with changes not written in another editor is not
-- touched. Returns the lines taken out, the files left to write, and the files
-- not touched.
function M.remove(files, wanted)
  local removed, unsaved, skipped = 0, {}, {}
  for _, file in ipairs(files) do
    local buf, loaded_here, other = load(file)
    if held(other) then
      skipped[#skipped + 1] = file
    else
      local here = 0
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for lnum = #lines, 1, -1 do
        local mark = M.parse(lines[lnum])
        if mark and wanted(mark, lnum) then
          vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, {})
          here = here + 1
        end
      end
      removed = removed + here
      if here > 0 and not save_if_only_debug(buf, loaded_here) then
        unsaved[#unsaved + 1] = file
      end
    end
    if loaded_here then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  return removed, unsaved, skipped
end

-- Puts a debug line in below the cursor: a template of the language, or a
-- line typed.
-- The most lines typed a project keeps for a language.
local TYPED = 10

-- The lines typed at <leader>di in a project for a language, the latest
-- first: an output function of the project's own (BIO_printf, a logging
-- macro) is typed once and chosen after. `add` puts a line first, `drop`
-- forgets it.
local function typed_lines(root, filetype, add, drop)
  if not root then
    return {}
  end
  local data = stored(root)
  local lines = type(data.typed[filetype]) == "table" and data.typed[filetype] or {}
  if add or drop then
    lines = vim.tbl_filter(function(line)
      return line ~= add and line ~= drop
    end, lines)
    if add then
      table.insert(lines, 1, add)
    end
    data.typed[filetype] = { unpack(lines, 1, TYPED) }
    write_store(root, data)
  end
  return lines
end

-- The lines offered for a language: the templates here, those set in
-- vim.g.debug_line_templates (lua/config/local.lua, out of the repository,
-- for an output function whose name is not to be published), then the lines
-- typed in the project, none twice.
local function offered(root, filetype)
  local own = vim.g.debug_line_templates or {}
  local lines, seen = {}, {}
  local function add(list, kind)
    for _, line in ipairs(type(list) == "table" and list or {}) do
      if type(line) == "string" and not seen[line] then
        seen[line] = true
        lines[#lines + 1] = { text = line, kind = kind }
      end
    end
  end
  add(M.templates[filetype], "template")
  add(own[filetype] or filetype == "cpp" and own.c, "set")
  add(typed_lines(root, filetype), "typed")
  return lines
end

-- The lines a choice would put in, shown below the line they go after while
-- it is the one under the cursor in the list: the number, the indent and the
-- mark as they will be, so where it lands and how it reads are seen before.
local preview = vim.api.nvim_create_namespace("taka.debug_lines.preview")

local function show_preview(buf, row, lines)
  -- The buffer may be gone by the time the list closes.
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, preview, 0, -1)
  if not lines then
    return
  end
  local spaces = string.rep(" ", vim.bo[buf].tabstop)
  vim.api.nvim_buf_set_extmark(buf, preview, row - 1, 0, {
    virt_lines = vim.tbl_map(function(line)
      return { { (line:gsub("\t", spaces)), "DebugLinePreview" } }
    end, lines),
  })
end

function M.insert()
  local buf, row = vim.api.nvim_get_current_buf(), vim.fn.line(".")
  local file = vim.api.nvim_buf_get_name(buf)
  -- From the name when the buffer has none set yet.
  local filetype = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or filetype_of(file)
  local root = root_of(buf)
  local typed = { text = "Type a line ({tag}, {n} and {where} are filled in)", kind = "type" }
  local choices = vim.list_extend(offered(root, filetype), { typed })
  local function preview_of(choice)
    if not choice then
      return show_preview(buf, row, nil)
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = choice.kind == "type" and "(the line typed goes here)" or choice.text
    show_preview(
      buf,
      row,
      build(text, file, filetype, row, lines, false, group_of(root), take_number(root, lines, true))
    )
  end
  local function put(text, kind)
    show_preview(buf, row, nil)
    if not text or vim.trim(text) == "" then
      return
    end
    if kind == "type" or kind == "typed" then
      typed_lines(root, filetype, text)
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local new = build(text, file, filetype, row, lines, false, group_of(root), take_number(root, lines))
    vim.api.nvim_buf_set_lines(buf, row, row, false, new)
    vim.api.nvim_win_set_cursor(0, { row + 1, #new[1]:match("^%s*") })
    if file ~= "" then
      remember(root_of(buf), file)
    end
    -- A file not written yet is the reader's to write the first time.
    if not save_if_only_debug(buf, false) and file ~= "" and vim.uv.fs_stat(file) then
      vim.notify("Debug line put in; not written, as the file has other changes")
    end
    M.refresh()
  end
  vim.ui.select(choices, {
    prompt = "Debug line" .. (group_of(root) and (" (" .. group_of(root) .. ")") or ""),
    format_item = function(choice)
      return choice.text .. (choice.kind == "typed" and "  (typed before; <C-x> forgets it)" or "")
    end,
    -- <C-x> forgets a line typed before, as it takes an entry out elsewhere.
    snacks = {
      on_change = function(_, item)
        preview_of(item and item.item)
      end,
      actions = {
        debug_line_forget = function(picker)
          local current = picker:current()
          local choice = current and current.item
          if choice and choice.kind == "typed" then
            typed_lines(root, filetype, nil, choice.text)
            picker:close()
            vim.schedule(M.insert)
          end
        end,
      },
      win = {
        input = { keys = { ["<c-x>"] = { "debug_line_forget", mode = { "n", "i" }, desc = "Forget the line typed" } } },
      },
    },
  }, function(choice)
    show_preview(buf, row, nil)
    if choice == typed then
      preview_of(typed)
      vim.ui.input({ prompt = "Debug line: " }, function(text)
        put(text, "type")
      end)
    elseif choice then
      put(choice.text, choice.kind)
    end
  end)
end

-- Makes the lines selected debug lines, one block with one number: lines
-- written as any code is, with completion and the indent of the place, then
-- marked, for a block too long to type at a prompt. Blank lines and lines
-- marked already are left as they are; {tag}, {n} and {where} are filled in.
function M.mark_selection()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  local file = vim.api.nvim_buf_get_name(buf)
  -- From the name when the buffer has none set yet.
  local filetype = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or filetype_of(file)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local n, count = take_number(root_of(buf), lines), 0
  for row = first, last do
    local line = lines[row]
    if line:find("%S") and not M.parse(line) then
      local new =
        build(line:match("^%s*(.*)$"), file, filetype, row - 1, lines, false, group_of(root_of(buf)), n, false)[1]
      -- Its own indent, not that of the line above.
      new = line:match("^%s*") .. new:gsub("^%s*", "")
      vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { new })
      count = count + 1
    end
  end
  if count > 0 and file ~= "" then
    remember(root_of(buf), file)
  end
  local written = count > 0 and file ~= "" and vim.uv.fs_stat(file) ~= nil and save_if_only_debug(buf, false)
  vim.notify(
    ("%d lines made debug line #%d%s"):format(
      count,
      n,
      written == false and "; not written, as the file has other changes" or ""
    )
  )
  M.refresh()
end

-- Sets the group of the lines put in by hand; empty for none.
-- Kept with the project, so it stays after a restart, and shown in the
-- statusline beside the count.
function M.set_group()
  local root = root_of(0)
  vim.ui.input(
    { prompt = "Group of the debug lines (empty for none): ", default = group_of(root) or "" },
    function(text)
      if text == nil then
        return
      end
      text = vim.trim(text)
      if text ~= "" and not text:match(GROUP) then
        vim.notify("A group is letters, digits, _ . and -", vim.log.levels.WARN)
        return
      end
      local group = text ~= "" and text or nil
      if root then
        local data = stored(root)
        data.group = group
        write_store(root, data)
        M.refresh()
      else
        M.group = group
      end
      vim.notify(group and ("Debug lines go into " .. group) or "Debug lines have no group")
    end
  )
end

local function who(item)
  return (item.ai and "AI " or "") .. (item.group ~= "" and item.group or "-")
end

local function need_rg()
  if vim.fn.executable("rg") == 0 then
    vim.notify("rg is not on PATH", vim.log.levels.ERROR)
    return false
  end
  return true
end

-- The debug lines of the project, handed to `done` with the root when there
-- are any (else `none` is called, if given): in the files known to hold some,
-- or with `everywhere` in all. The
-- search shows in the statusline while it runs (every file of a large tree
-- takes a while), and none found says where it looked.
local function look(done, everywhere, none)
  if everywhere and not need_rg() then
    return
  end
  local root = root_of(0)
  if not root then
    vim.notify("Not in a project (GTAGS, .git or .svn): open a file of one, or :cd into it", vim.log.levels.WARN)
    return
  end
  local answered = require("taka.lib.activity").begin("debug lines")
  M.find(root, function(items)
    answered(#items == 0 and "none" or ("%d found"):format(#items))
    if #items == 0 and none then
      return none()
    elseif #items == 0 then
      local where = everywhere and "" or " in the files known to hold some (<leader>dL looks in all)"
      vim.notify("No debug lines under " .. root .. where, vim.log.levels.WARN)
      return
    end
    done(items, root)
  end, everywhere)
end

-- The debug lines as the reader counts them: the lines of one number in a
-- file are one entry, at the first of them, with `end_lnum` at the last and
-- `count` of the lines; a line with no number is one entry of its own. A
-- block of ten lines is one debug line, as its log line and <leader>dj say.
function M.blocks(items)
  local entries, by_number = {}, {}
  for _, item in ipairs(items) do
    local key = item.n and (item.filename .. "#" .. item.n)
    local entry = key and by_number[key]
    if entry then
      entry.end_lnum = math.max(entry.end_lnum, item.lnum)
      entry.count = entry.count + 1
    else
      entry = vim.tbl_extend("force", item, { end_lnum = item.lnum, count = 1 })
      entries[#entries + 1] = entry
      if key then
        by_number[key] = entry
      end
    end
  end
  return entries
end

-- The debug lines of the project, in a list with a preview; with
-- `everywhere`, searched for in every file.
function M.list(everywhere)
  look(function(items)
    local entries = M.blocks(items)
    local ai = #vim.tbl_filter(function(entry)
      return entry.ai
    end, entries)
    for _, entry in ipairs(entries) do
      -- What the list's keys need of the entry: the quickfix list keeps it.
      entry.user_data = { n = entry.n, lnum = entry.lnum, end_lnum = entry.end_lnum }
      local more = entry.count > 1 and (" (+%d line%s)"):format(entry.count - 1, entry.count > 2 and "s" or "") or ""
      entry.text = ("[%s] %s%s"):format(who(entry), entry.text, more)
    end
    local title = ("Debug lines: %d (AI %d)"):format(#entries, ai)
    vim.fn.setqflist({}, " ", { title = title, items = entries })
    Snacks.picker.qflist({
      title = title,
      actions = {
        debug_line_out = function(picker)
          M.remove_entries(picker:selected({ fallback = true }))
          picker:close()
          vim.schedule(function()
            M.list(everywhere)
          end)
        end,
      },
      -- The keys of the buffer list, where they take a buffer out.
      win = {
        input = { keys = { ["<c-x>"] = { "debug_line_out", mode = { "n", "i" }, desc = "Take the debug line out" } } },
        list = { keys = { ["dd"] = { "debug_line_out", desc = "Take the debug line out" } } },
      },
    })
  end, everywhere)
end

-- What taking lines out said: `done`, then the files left to write, as they
-- had other changes, and those not touched, open with changes in another
-- editor.
function M.removal_message(done, unsaved, skipped)
  local message = done
  if #unsaved > 0 then
    message = message .. "; not written, as they had other changes: " .. table.concat(unsaved, ", ")
  end
  if #skipped > 0 then
    message = message
      .. "; not touched, as another editor has changes not written in them: "
      .. table.concat(skipped, ", ")
  end
  return message
end

-- Takes out the debug lines of entries chosen in the list (<C-x>, or several
-- marked with <Tab>): every line of an entry's number in its file, or the one
-- line of an entry with none.
function M.remove_entries(chosen)
  local by_file, files = {}, {}
  for _, item in ipairs(chosen) do
    local data = item.item and item.item.user_data
    if type(data) == "table" and item.file then
      local file = vim.fs.normalize(item.file)
      if not by_file[file] then
        by_file[file] = {}
        files[#files + 1] = file
      end
      table.insert(by_file[file], data)
    end
  end
  local removed, unsaved, skipped = 0, {}, {}
  for _, file in ipairs(files) do
    local entries = by_file[file]
    local here, left, held_files = M.remove({ file }, function(mark, lnum)
      for _, data in ipairs(entries) do
        if data.n and mark.n == data.n or not data.n and lnum == data.lnum then
          return true
        end
      end
      return false
    end)
    removed = removed + here
    vim.list_extend(unsaved, left)
    vim.list_extend(skipped, held_files)
  end
  vim.notify(M.removal_message(("%d lines taken out"):format(removed), unsaved, skipped))
end

-- The number of the debug line a line of a log names, as printed by {tag}
-- (`[DBG 12 path-A]`, `[DBG-AI 7]`, and `[DBG path-A 12]` as lines put in
-- before the number came first print it): the one nearest the cursor when
-- the line names several.
function M.number_in(line, col)
  local best, distance
  for start, inside, stop in line:gmatch("()%[(DBG[%w_.%- ]-)%]()") do
    -- The word after DBG, or, in the older order, the last word; a word of its
    -- own either way: in `DBG x1` the 1 is the group's.
    local words = vim.split(vim.trim(inside), "%s+")
    local n = words[2] and words[2]:match("^%d+$") or #words > 2 and words[#words]:match("^%d+$")
    local away = col and math.min(math.abs(col - start), math.abs(col - stop)) or 0
    if n and (not distance or away < distance) then
      best, distance = tonumber(n), away
    end
  end
  return best
end

-- Goes to the debug line whose number the line under the cursor prints (a
-- log in a terminal, a file or the output of a run), or one typed. Looked for
-- in the files known, then in every file.
function M.jump()
  local n = M.number_in(vim.api.nvim_get_current_line(), vim.fn.col("."))
  local function go(number)
    number = tonumber(number)
    if not number then
      return
    end
    local function search(everywhere, after)
      look(function(items)
        for _, item in ipairs(items) do
          if item.n == number then
            -- From a terminal, the file opens in the window before it, and
            -- the log stays where it was.
            local back = vim.fn.win_getid(vim.fn.winnr("#"))
            if vim.bo.buftype ~= "" and back ~= 0 and vim.bo[vim.api.nvim_win_get_buf(back)].buftype == "" then
              vim.api.nvim_set_current_win(back)
            end
            vim.cmd.edit(vim.fn.fnameescape(item.filename))
            vim.api.nvim_win_set_cursor(0, { item.lnum, 0 })
            vim.cmd("normal! ^")
            return
          end
        end
        after()
      end, everywhere, after)
    end
    search(false, function()
      search(true, function()
        vim.notify(("No debug line #%d"):format(number), vim.log.levels.WARN)
      end)
    end)
  end
  if n then
    return go(n)
  end
  vim.ui.input({ prompt = "Debug line number: " }, go)
end

-- Takes debug lines out of the project: all of them, those put in by hand,
-- those of an agent, or one group, chosen from what is there.
function M.clear()
  look(function(items, root)
    local choices = {}
    local function choice(label, wanted)
      local files, count = {}, 0
      for _, entry in ipairs(M.blocks(items)) do
        if wanted(entry) then
          count = count + 1
          if files[#files] ~= entry.filename then
            files[#files + 1] = entry.filename
          end
        end
      end
      if count > 0 then
        choices[#choices + 1] = { label = ("%s (%d)"):format(label, count), wanted = wanted, files = files }
      end
    end
    choice("All", function()
      return true
    end)
    choice("Put in by hand", function(mark)
      return not mark.ai
    end)
    choice("Put in by an agent", function(mark)
      return mark.ai
    end)
    local groups = {}
    for _, item in ipairs(items) do
      if item.group ~= "" and not groups[item.group] then
        groups[item.group] = true
        local group = item.group
        choice("Group " .. group, function(mark)
          return mark.group == group
        end)
      end
    end
    vim.ui.select(choices, {
      prompt = "Take out the debug lines",
      format_item = function(entry)
        return entry.label
      end,
    }, function(entry)
      if not entry then
        return
      end
      local removed, unsaved, skipped = M.remove(entry.files, entry.wanted)
      -- Read again, so a file left with no lines is let go of.
      M.find(root, function() end)
      vim.notify(M.removal_message(("%s: %d lines taken out"):format(entry.label, removed), unsaved, skipped))
    end)
  end)
end

-- The command line an agent uses, run in a headless editor:
--   nvim --headless "+lua require('taka.debug_lines').cli{'add', 'src/a.c', '120', 'path-B'}" +qa
--   add FILE LINE [GROUP]  puts a line in after LINE (0 for the top), the text
--                          from $DEBUG_LINE_TEXT (lines split at \n), else the
--                          first template of the language
--   list [GROUP]           the debug lines of the project the working
--                          directory is in, in the files known to hold some
--   clear [GROUP]          takes out the lines an agent put in, and no other
-- What it did goes to stdout; on a mistake it ends with exit code 1.
function M.cli(args)
  args = type(args) == "string" and vim.split(vim.trim(args), "%s+") or args
  local function out(text)
    io.stdout:write(text .. "\n")
  end
  local function fail(text)
    out("error: " .. text)
    io.stdout:flush()
    vim.cmd("cquit 1")
  end
  local what, group = args[1], nil
  if what == "add" then
    local file, row = args[2], tonumber(args[3])
    group = args[4]
    if not file or vim.fn.filereadable(file) == 0 then
      return fail("no such file: " .. tostring(file))
    end
    local buf, loaded_here, other = load(file)
    if held(other) then
      return fail(("not put in %s: %s; write it there first"):format(file, held(other)))
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if not row or row < 0 or row > #lines or row % 1 ~= 0 then
      return fail(("line %s is not in the file (0 to %d)"):format(tostring(args[3]), #lines))
    end
    if group and not group:match(GROUP) then
      return fail("a group is letters, digits, _ . and -")
    end
    local filetype = filetype_of(file)
    local text = vim.env.DEBUG_LINE_TEXT
    text = text and text ~= "" and text or (M.templates[filetype] or {})[1]
    if not text then
      return fail("no template for " .. (filetype ~= "" and filetype or "this file") .. "; set DEBUG_LINE_TEXT")
    end
    local new = build(text, file, filetype, row, lines, true, group, take_number(root_of(buf), lines))
    vim.api.nvim_buf_set_lines(buf, row, row, false, new)
    save(buf, loaded_here)
    remember(root_of(buf), file)
    if lines[row] then
      out(("%s:%d: %s"):format(file, row, lines[row]))
    end
    for i, line in ipairs(new) do
      out(("%s:%d: %s"):format(file, row + i, line))
    end
    return
  end
  if what ~= "list" and what ~= "clear" then
    return fail("use add, list or clear")
  end
  group = args[2]
  local root = root_of(0)
  if not root then
    return fail("not in a project (GTAGS, .git or .svn); run this from inside one")
  end
  local items
  M.find(root, function(found)
    items = found
  end)
  vim.wait(60000, function()
    return items ~= nil
  end, 20)
  items = vim.tbl_filter(function(item)
    return not group or item.group == group
  end, items or {})
  if what == "list" then
    for _, item in ipairs(items) do
      out(
        ("%s:%d: [%s] %s"):format(
          vim.fs.normalize(vim.fn.fnamemodify(item.filename, ":.")),
          item.lnum,
          who(item),
          item.text
        )
      )
    end
    out(("%d debug lines"):format(#items))
    return
  end
  local files = {}
  for _, item in ipairs(items) do
    if item.ai and files[#files] ~= item.filename then
      files[#files + 1] = item.filename
    end
  end
  local removed, _, skipped = M.remove(files, function(mark)
    return mark.ai and (not group or mark.group == group)
  end)
  M.find(root, function() end)
  out(("%d debug lines taken out"):format(removed))
  for _, file in ipairs(skipped) do
    out(
      ("not taken out of %s: it has changes not written in another editor; write it there first"):format(
        vim.fs.normalize(vim.fn.fnamemodify(file, ":."))
      )
    )
  end
end

-- Counts the debug lines of the current project again, for the statusline:
-- once for any number of calls in a row, and only in the files known, so it
-- is cheap enough to do on entering a buffer.
local counting = false
function M.refresh()
  if counting then
    return
  end
  counting = true
  vim.schedule(function()
    counting = false
    if vim.bo.buftype ~= "" then
      return
    end
    local root = root_of(0)
    if not root then
      vim.g.debug_lines_count = nil
      return
    end
    M.find(root, function() end)
  end)
end

vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "DirChanged" }, {
  group = vim.api.nvim_create_augroup("taka_debug_lines", { clear = true }),
  callback = function()
    M.refresh()
  end,
})

-- The lines lit where they stand, a line of an agent in a colour of its own,
-- drawn as the window is: a line put in, moved or taken out needs nothing
-- kept up to date. The colour is below the others of the line, so a word lit
-- on it still shows.
vim.api.nvim_set_hl(0, "DebugLine", { link = "DiagnosticVirtualTextWarn", default = true })
vim.api.nvim_set_hl(0, "DebugLineAI", { link = "DiagnosticVirtualTextHint", default = true })
vim.api.nvim_set_hl(0, "DebugLinePreview", { link = "Comment", default = true })
-- The mark at the end of a line, in the colour of the diagnostic of its kind
-- and bold, so it is seen as more than a comment.
local function mark_colours()
  for name, from in pairs({ DebugLineMark = "DiagnosticWarn", DebugLineMarkAI = "DiagnosticHint" }) do
    local fg = vim.api.nvim_get_hl(0, { name = from, link = false }).fg
    vim.api.nvim_set_hl(0, name, { fg = fg, bold = true, default = true })
  end
end
mark_colours()
vim.api.nvim_create_autocmd("ColorScheme", { callback = mark_colours })
local namespace = vim.api.nvim_create_namespace("taka.debug_lines")
vim.api.nvim_set_decoration_provider(namespace, {
  on_win = function(_, _, buf)
    return vim.bo[buf].buftype == ""
  end,
  on_line = function(_, _, buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    -- The mark is at the end, so a line without DBG in it is passed cheaply.
    local mark = line and line:find("DBG", 1, true) and M.parse(line)
    if mark then
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        end_col = #line,
        hl_group = mark.ai and "DebugLineAI" or "DebugLine",
        ephemeral = true,
        priority = 10,
      })
      -- The mark itself in the colour of who put it in: the background is
      -- kept faint so the code on it reads, and alone it was near the cursor
      -- line's, and the mark was grey like any comment. Above the comment's
      -- own colour from the syntax.
      local from = line:find("/%*%s*DBG[^/]*%*/") or line:find("[/%-#]+%s*DBG")
      if from then
        vim.api.nvim_buf_set_extmark(buf, namespace, row, from - 1, {
          end_col = #line,
          hl_group = mark.ai and "DebugLineMarkAI" or "DebugLineMark",
          ephemeral = true,
          priority = 150,
        })
      end
    end
  end,
})

return M

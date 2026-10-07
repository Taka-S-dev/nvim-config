-- Looking names up in GTAGS, with tags where it has none: the definitions
-- of a name, the jump to them, and the cscope-style queries behind
-- <leader>j*.
--
-- Every query here asks `global` directly instead of going through cscope_maps.
--
-- cscope_maps answers each query by starting gtags-cscope.exe, which starts
-- global.exe, and waits for both with vim.system():wait(), freezing the editor
-- until they exit. Asking global directly drops one process start (about 90 ms
-- to 20 ms per lookup on the openssl tree), and running it asynchronously means
-- the editor keeps responding however slow process starts are made by security
-- software. Each cscope query has a global equivalent that returns the same
-- matches: definitions -d, references -r, other symbols -s, text -g, files -P.
--
-- How global is started lives in lua/taka/lib/gtags_global.lua, which also
-- handles a global.exe that cannot write its results to Neovim's pipe.
--
-- A resident gtags-cscope was measured and rejected: it still starts global.exe
-- for every query. Loading every definition up front was rejected too: it is
-- instant on openssl but takes over a minute and 1.3 GB on a Linux kernel tree.
--
-- The database is picked from the file being edited, not from the cwd, so a
-- file opened from another project -- routine with the remote-tab workflow in
-- bin/open-in-nvim.cmd -- queries its own GTAGS.

-- Definition results are kept per project until its GTAGS changes, so a
-- repeated jump starts no process at all. Other queries are not cached: they
-- are browsed, not repeated. A name global found nothing for is not kept
-- either: an empty answer can be one that failed to arrive, from a GTAGS being
-- rebuilt or a global.exe whose output did not reach Neovim that once, and kept
-- it would hide the definition until Neovim was restarted.
local definitions = {} ---@type table<string, { mtime: integer, symbols: table<string, table[]> }>

local function definitions_of(root)
  local stat = vim.uv.fs_stat(vim.fs.joinpath(root, "GTAGS"))
  local mtime = stat and stat.mtime.sec or 0
  local project = definitions[root]
  if not project or project.mtime ~= mtime then
    project = { mtime = mtime, symbols = {} }
    definitions[root] = project
  end
  return project.symbols
end

local function gtags_root()
  local name = vim.api.nvim_buf_get_name(0)
  return require("taka.lib.gtags_global").root(name)
end

-- `global -ax*` prints `name  line  absolute-path  source-line`.
local function parse(output)
  local items = {}
  for line in vim.gsplit(output, "\n", { trimempty = true }) do
    local lnum, file, text = line:gsub("\r$", ""):match("^%S+%s+(%d+)%s+(%S+)%s?(.*)$")
    if lnum then
      items[#items + 1] = { filename = file, lnum = tonumber(lnum), col = 1, text = vim.trim(text) }
    end
  end
  return items
end

-- The lines of `filename` as they are now: from its buffer when it is open, an
-- edit not yet saved included, else from the disk. GTAGS and the tags file hold
-- the bytes of the file, so a buffer read from another encoding, Shift-JIS
-- say, is read from the disk instead, where those bytes are.
local function current_lines(filename)
  local want = vim.fs.normalize(filename):lower()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)):lower() == want
      and vim.tbl_contains({ "", "utf-8" }, vim.bo[buf].fileencoding)
    then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  local ok, read = pcall(vim.fn.readfile, filename)
  return ok and read or {}
end

-- The whitespace of a line made one space, as lines are compared below: the
-- line GTAGS holds and the line in the file may be laid out apart.
local function anchor_key(line)
  return vim.trim(line:gsub("%s+", " "))
end

-- The line a definition is on now. GTAGS is not brought up to date by an edit,
-- so its line number goes on pointing where the definition was; lines added
-- above it carried a jump and a peek that many lines off. The text of the line
-- that GTAGS keeps with each definition is looked for in the file, the buffer
-- when it is open, so an edit not yet saved counts too. The line moves only
-- when that text stands on exactly one line: on none or on several, the number
-- GTAGS gives is kept, rather than a place that looks right and is not. A text
-- of the name alone, or of no more than a word, says too little to look for.
local function heal(item)
  local key = anchor_key(item.text or "")
  if not key:find("[^%w_]") then
    return item
  end
  local lines = current_lines(item.filename)
  if lines[item.lnum] and anchor_key(lines[item.lnum]) == key then
    return item
  end
  local found
  for i, line in ipairs(lines) do
    if anchor_key(line) == key then
      if found then
        return item
      end
      found = i
    end
  end
  return found and vim.tbl_extend("force", item, { lnum = found }) or item
end

-- How many a lookup found, for the statusline: "gtags: name  40 ms (global,
-- 2 found)". Without the count a lookup that found nothing, and so went on to
-- the tags, read the same as one that found the definition.
local function found(items)
  return #items == 0 and "nothing found" or ("%d found"):format(#items)
end

local function open_picker(title, items)
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if Snacks and Snacks.picker then
    -- The jump goes on the tag stack when one is chosen, from where the list
    -- was opened; none when the list is closed.
    Snacks.picker.qflist({ jump = { tagstack = true } })
  else
    vim.cmd.copen()
  end
end

-- One result opens directly; several open in the quickfix picker. The origin
-- goes on the tag stack, so <C-t> returns here: at once for one, and for
-- several when one is chosen. Pushed as the list opened, a list closed without
-- a choice left a level that went nowhere, landed where it started.
---@param from? table position recorded by the caller, for when the jump starts
---from somewhere the cursor has already left, such as the peek window.
local function show(title, symbol, items, from)
  if not from then
    from = vim.fn.getpos(".")
    from[1] = vim.api.nvim_get_current_buf()
  end
  -- <C-]> on a name where it is defined, as on a macro in its own #define:
  -- the only definition is the line the jump starts from. Nothing moves, and
  -- nothing goes on the tag stack, where it made a level of the jump stack
  -- that leads nowhere.
  local origin = vim.fs.normalize(vim.api.nvim_buf_get_name(from[1])):lower()
  if #items == 1 and items[1].lnum == from[2] and vim.fs.normalize(items[1].filename):lower() == origin then
    vim.notify(symbol .. " is defined here")
    return
  end
  if #items == 1 then
    vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = { { tagname = symbol, from = from } } }, "t")
    vim.cmd("normal! m'")
    -- A definition in the file already open is reached without :edit, which
    -- would read the file again and have its language server attach anew.
    local here = vim.fs.normalize(vim.api.nvim_buf_get_name(0)):lower()
    if vim.fs.normalize(items[1].filename):lower() ~= here then
      vim.cmd.edit(vim.fn.fnameescape(items[1].filename))
    end
    -- A language server says the column; GTAGS gives the line only.
    if (items[1].col or 1) > 1 then
      vim.api.nvim_win_set_cursor(0, { items[1].lnum, items[1].col - 1 })
    else
      vim.api.nvim_win_set_cursor(0, { items[1].lnum, 0 })
      vim.cmd("normal! ^")
    end
    return
  end
  open_picker(title, items)
end

-- Where a tag points, as a line number. ctags records the `line:` field when
-- asked to, a bare number for some kinds, and otherwise the text of the line as
-- a search pattern, cut short when the line is long. The file is compared as
-- bytes, the way the tags file holds it, so a Shift-JIS source matches too.
--
-- The tags file is not brought up to date by an edit either, so its line
-- number is kept only while the line there still starts with the text it
-- recorded; else the line with that text nearest to it is taken, as the jump
-- through GTAGS is placed. A file open is read from its buffer, an edit not
-- yet saved included.
local function tag_line(tag, filename)
  local number = tonumber(tag.line) or tonumber(tag.cmd)
  local text = not tonumber(tag.cmd) and tag.cmd:gsub("^[/?]%^?", ""):gsub("%$?[/?]$", ""):gsub("\\([/\\?])", "%1")
  if not text or text == "" then
    return number or 1
  end
  local lines = current_lines(filename)
  if number and lines[number] and lines[number]:sub(1, #text) == text then
    return number
  end
  local nearest
  for i, line in ipairs(lines) do
    if
      line:sub(1, #text) == text and (not nearest or math.abs(i - (number or 1)) < math.abs(nearest - (number or 1)))
    then
      nearest = i
    end
  end
  return nearest or number or 1
end

-- The ctags fallback. :tjump would do for one match, but with several it
-- prints Vim's numbered list at the bottom of the screen and waits for a
-- number, while the same situation from gtags opens the picker. So the tags are
-- read here and shown the way the gtags results are.
--
-- The pattern has to begin with ^: only then does Vim look the name up by
-- binary search in the sorted tags file. With anything in front of it the whole
-- file is read, which on the 1.4 GB tags of a kernel tree took 5 seconds where
-- this takes a millisecond. \C, a tag matched as written whatever 'ignorecase'
-- says, works just as well at the end.
local function ctags_definitions(symbol)
  local ok, tags = pcall(vim.fn.taglist, "^" .. vim.fn.escape(symbol, [=[\^$.*~[]]=]) .. "$\\C")
  local items, seen = {}, {}
  for _, tag in ipairs(ok and tags or {}) do
    local filename = vim.fn.fnamemodify(tag.filename, ":p")
    local lnum = tag_line(tag, filename)
    local id = filename .. ":" .. lnum
    if not seen[id] then
      seen[id] = true
      local text = tag.cmd:gsub("^[/?]%^?", ""):gsub("%$?[/?]$", "")
      items[#items + 1] = { filename = filename, lnum = lnum, col = 1, text = vim.trim(text) }
    end
  end
  require("taka.lib.activity").begin("ctags: " .. symbol)(found(items))
  return items
end

local function jump_with_ctags(symbol)
  local items = ctags_definitions(symbol)
  if #items == 0 then
    vim.notify("No definition found for " .. symbol, vim.log.levels.WARN)
    return
  end
  show("Definitions of " .. symbol .. " (ctags)", symbol, items)
end

-- Run one or more `global` invocations in the project root and hand the merged
-- results to `done`, on the main loop, only if the user is still where they
-- asked from.
--
-- Every lookup says what it is doing in the statusline: a spinner and the name
-- while global has not answered, then how long the answer took and where it
-- came from. Starting global.exe can take seconds where process starts are
-- inspected, and without this nothing on screen tells a lookup that is running
-- from a key press that was lost.
--
-- It is the statusline rather than a notification because the message is only
-- true for a moment: a popup crosses the code being read and stays in the
-- notification history. lua/taka/lib/activity.lua keeps what is running.

---Show `label` as being looked up. The returned function reports the answer.
local function begin_lookup(label)
  return require("taka.lib.activity").begin("gtags: " .. label)
end

local function run_global(root, invocations, done, label)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local items, pending = {}, #invocations
  local answered = begin_lookup(label)
  for _, args in ipairs(invocations) do
    require("taka.lib.gtags_global").run(root, args, function(output)
      vim.list_extend(items, parse(output))
      pending = pending - 1
      if pending > 0 then
        return
      end
      answered("global, " .. found(items))
      if vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf then
        done(items)
      end
    end)
  end
end

-- The definitions a language server gives for the word at the cursor, for a
-- file no GTAGS covers, as in Go or Lua: the same items a lookup in GTAGS
-- gives, so the jump, the list of several and the peek treat them alike. false
-- when no server attached to the buffer answers definitions.
local function lsp_definitions(symbol, done)
  local method = "textDocument/definition"
  local buf = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  if #clients == 0 then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local answered = begin_lookup(symbol)
  vim.lsp.buf_request_all(buf, method, function(client)
    return vim.lsp.util.make_position_params(win, client.offset_encoding)
  end, function(results)
    local items, seen = {}, {}
    for id, response in pairs(results) do
      local client = vim.lsp.get_client_by_id(id)
      local answer = response.result
      if answer and client then
        -- One location, or a list of them.
        answer = (answer.uri or answer.targetUri) and { answer } or answer
        for _, item in ipairs(vim.lsp.util.locations_to_items(answer, client.offset_encoding)) do
          local key = item.filename .. ":" .. item.lnum
          if not seen[key] then
            seen[key] = true
            items[#items + 1] =
              { filename = item.filename, lnum = item.lnum, col = item.col, text = vim.trim(item.text or "") }
          end
        end
      end
    end
    answered("lsp, " .. found(items))
    if vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf then
      done(items, "lsp")
    end
  end)
  return true
end

---Look the definitions of `symbol` up and hand them to `done`. `done` is not
---called when there is no database or no global to ask, nor a language server.
local function lookup_definition(symbol, done, no_database)
  local root = gtags_root()
  if not root or vim.fn.executable("global") == 0 then
    if not root and lsp_definitions(symbol, done) then
      return
    end
    return no_database()
  end
  local symbols = definitions_of(root)
  local function finish(items, source)
    -- Found nothing is not kept; see the top of this file.
    if #items > 0 then
      symbols[symbol] = items
    end
    -- Placed where the definitions are now each time, the ones kept included:
    -- the file may have changed since they were looked up.
    done(vim.tbl_map(heal, items), source)
  end
  if symbols[symbol] then
    -- No global to wait for, but the statusline still says the key was heard.
    begin_lookup(symbol)("memory, " .. found(symbols[symbol]))
    return finish(symbols[symbol], "memory")
  end
  run_global(root, { { "-axd", symbol } }, function(items)
    finish(items, "global")
  end, symbol)
end

-- The last jump, for :GtagsJumpDebug: what started it, where the answer came
-- from and how long it took. A jump that feels slow from one input and quick
-- from another is either answered from memory in one case only, or slow before
-- the mapping runs at all; the numbers say which.
local jump_trace = {}

local function jump_to_definition(symbol, trigger)
  if not symbol or symbol == "" then
    return
  end
  jump_trace = { trigger = trigger or "key", symbol = symbol, started = vim.uv.hrtime() }
  lookup_definition(symbol, function(items, source)
    jump_trace.source, jump_trace.answered = source, vim.uv.hrtime()
    if #items == 0 then
      -- gtags has no entry, e.g. for a source it could not parse.
      jump_trace.source = source .. ", then ctags"
      jump_with_ctags(symbol)
    else
      show("Definitions of " .. symbol, symbol, items)
    end
    jump_trace.landed = vim.uv.hrtime()
  end, function()
    jump_trace.source, jump_trace.answered = "ctags", vim.uv.hrtime()
    jump_with_ctags(symbol)
    jump_trace.landed = vim.uv.hrtime()
  end)
end

-- The cscope-style queries behind <leader>j*.
local queries = {
  -- -s finds names gtags does not record as definitions, such as enum members;
  -- without it an enum constant used 103 times shows no occurrences at all.
  s = {
    title = "Occurrences of",
    args = function(s)
      return { { "-axd", s }, { "-axr", s }, { "-axs", s } }
    end,
  },
  c = {
    title = "Callers of",
    args = function(s)
      return { { "-axr", s } }
    end,
  },
  t = {
    title = "Text",
    args = function(s)
      return { { "-axg", "--literal", s } }
    end,
  },
  f = {
    title = "Files matching",
    args = function(s)
      return { { "-axP", s } }
    end,
  },
  -- gtags does not index #include, so match the directive text instead.
  i = {
    title = "Files including",
    args = function(s)
      local name = vim.fn.escape(vim.fs.basename(s), [[.^$*+?()[]{}|\]])
      return { { "-axg", [=[#[ \t]*include[ \t]*["<](.*/)?]=] .. name .. [=[[">]]=] } }
    end,
  },
}

-- The same keys where no GTAGS covers the file, as in Go or Lua: occurrences
-- and callers from the language server attached to the buffer, text and file
-- names searched in the files themselves, without an index. #include is C's
-- own.
local function without_gtags(kind, symbol)
  local server = function(method)
    return #vim.lsp.get_clients({ bufnr = 0, method = method }) > 0
  end
  if kind == "s" and server("textDocument/references") then
    return Snacks.picker.lsp_references()
  elseif kind == "c" and server("callHierarchy/incomingCalls") then
    return Snacks.picker.lsp_incoming_calls()
  elseif kind == "t" then
    return Snacks.picker.grep({ search = symbol, regex = false })
  elseif kind == "f" then
    return Snacks.picker.files({ pattern = vim.fs.basename(symbol) })
  end
  vim.notify("No GTAGS for this file. Build one with <leader>jb in the project root.", vim.log.levels.WARN)
end

local function query(kind, symbol)
  local spec = queries[kind]
  if not symbol or symbol == "" then
    return
  end
  local root = gtags_root()
  if not root then
    return without_gtags(kind, symbol)
  end
  if vim.fn.executable("global") == 0 then
    vim.notify("global is not on PATH", vim.log.levels.ERROR)
    return
  end
  run_global(root, spec.args(symbol), function(items)
    if #items == 0 then
      vim.notify(("%s %s: nothing found"):format(spec.title, symbol), vim.log.levels.WARN)
    else
      show(("%s %s"):format(spec.title, symbol), symbol, items)
    end
  end, ("%s %s"):format(spec.title, symbol))
end

local M = {}

M.root = gtags_root
M.begin = begin_lookup
M.show = show
M.ctags_definitions = ctags_definitions
M.lookup_definition = lookup_definition
M.jump = jump_to_definition
M.query = query

-- The last jump, for :GtagsJumpDebug.
function M.trace()
  return jump_trace
end

return M

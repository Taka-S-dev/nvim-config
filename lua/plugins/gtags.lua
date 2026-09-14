-- cscope-style navigation for legacy C using GNU Global (gtags) as backend.
--
-- Why not vim-gutentags? Neovim >=0.9 dropped built-in cscope support, so
-- gutentags's `gtags_cscope` module aborts at load. cscope_maps.nvim
-- reimplements the cscope command set in Lua and talks to `gtags-cscope`
-- directly.
--
-- Why a custom `:!gtags` build binding? cscope_maps's `:Cs db build` always
-- appends `-d <file>::<path>` to the build command for cscope semantics, but
-- the `gtags` binary doesn't accept `-d` — leaving it as the configured
-- builder yields "database build failed".
--
-- Why prefix `<leader>j` (not `<leader>c`)? `<leader>c*` is LazyVim's code
-- namespace (format, action, rename, etc.) and would collide.
--
-- Requires `gtags` on PATH (scoop install global, or winget GNU.GLOBAL).

-- Every query here asks `global` directly instead of going through cscope_maps.
--
-- cscope_maps answers each query by starting gtags-cscope.exe, which starts
-- global.exe, and waits for both with vim.system():wait(), freezing the editor
-- until they exit. Asking global directly drops one process start (117 ms to
-- 36 ms per lookup on the openssl tree), and running it asynchronously means
-- the editor keeps responding however slow process starts are made by security
-- software. Each cscope query has a global equivalent that returns the same
-- matches: definitions -d, references -r, text -g, files -P.
--
-- How global is started lives in config/gtags_global.lua, which also handles a
-- global.exe that cannot write its results to Neovim's pipe.
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
-- are browsed, not repeated.
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
  return name ~= "" and vim.fs.root(name, "GTAGS") or nil
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

local function jump_with_ctags(symbol)
  if not pcall(vim.cmd.tjump, symbol) then
    vim.notify("No definition found for " .. symbol, vim.log.levels.WARN)
  end
end

-- One result opens directly; several open in the quickfix picker. Either way
-- the origin is pushed on the tag stack, so <C-t> returns here.
local function show(title, symbol, items)
  local from = vim.fn.getpos(".")
  from[1] = vim.api.nvim_get_current_buf()
  vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = { { tagname = symbol, from = from } } }, "t")
  if #items == 1 then
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(items[1].filename))
    vim.api.nvim_win_set_cursor(0, { items[1].lnum, 0 })
    vim.cmd("normal! ^")
    return
  end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if Snacks and Snacks.picker then
    Snacks.picker.qflist()
  else
    vim.cmd.copen()
  end
end

-- Run one or more `global` invocations in the project root and hand the merged
-- results to `done`, on the main loop, only if the user is still where they
-- asked from.
local function run_global(root, invocations, done)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local items, pending = {}, #invocations
  for _, args in ipairs(invocations) do
    require("config.gtags_global").run(root, args, function(output)
      vim.list_extend(items, parse(output))
      pending = pending - 1
      if pending == 0 and vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf then
        done(items)
      end
    end)
  end
end

local function jump_to_definition(symbol)
  if not symbol or symbol == "" then
    return
  end
  local root = gtags_root()
  if not root or vim.fn.executable("global") == 0 then
    jump_with_ctags(symbol)
    return
  end
  local symbols = definitions_of(root)
  local function finish(items)
    symbols[symbol] = items
    if #items == 0 then
      -- gtags has no entry, e.g. for a source it could not parse.
      jump_with_ctags(symbol)
    else
      show("Definitions of " .. symbol, symbol, items)
    end
  end
  if symbols[symbol] then
    finish(symbols[symbol])
    return
  end
  run_global(root, { { "-axd", symbol } }, finish)
end

-- The cscope-style queries behind <leader>j*.
local queries = {
  s = { title = "Occurrences of", args = function(s) return { { "-axd", s }, { "-axr", s } } end },
  c = { title = "Callers of", args = function(s) return { { "-axr", s } } end },
  t = { title = "Text", args = function(s) return { { "-axg", "--literal", s } } end },
  f = { title = "Files matching", args = function(s) return { { "-axP", s } } end },
  -- gtags does not index #include, so match the directive text instead.
  i = {
    title = "Files including",
    args = function(s)
      local name = vim.fn.escape(vim.fs.basename(s), [[.^$*+?()[]{}|\]])
      return { { "-axg", [=[#[ \t]*include[ \t]*["<](.*/)?]=] .. name .. [=[[">]]=] } }
    end,
  },
}

local function query(kind, symbol)
  local spec = queries[kind]
  if not symbol or symbol == "" then
    return
  end
  local root = gtags_root()
  if not root then
    vim.notify("No GTAGS for this file. Build one with <leader>jb in the project root.", vim.log.levels.WARN)
    return
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
  end)
end

local function selected_text()
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return vim.trim(region[1] or "")
end

-- The file queries take the file name under the cursor, the rest the word.
local function under_cursor(kind)
  return vim.fn.expand((kind == "f" or kind == "i") and "<cfile>" or "<cword>")
end

local function query_key(lhs, kind, desc)
  return {
    { lhs, function() query(kind, under_cursor(kind)) end, desc = desc },
    { lhs, function() query(kind, selected_text()) end, desc = desc, mode = "x" },
  }
end

-- Ctrl+click: move the cursor to what was clicked, then jump. Vim's built-in
-- <C-LeftMouse> runs `:tag <cword>` directly and bypasses any remap of <C-]>.
local function jump_at_mouse()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= 0 and pos.line > 0 then
    vim.api.nvim_set_current_win(pos.winid)
    vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.column - 1, 0) })
  end
  jump_to_definition(vim.fn.expand("<cword>"))
end

local keys = {
  { "<C-]>", function() jump_to_definition(vim.fn.expand("<cword>")) end, desc = "Jump to definition" },
  { "<C-]>", function() jump_to_definition(selected_text()) end, desc = "Jump to definition", mode = "x" },
  { "<C-LeftMouse>", jump_at_mouse, desc = "Jump to definition (Ctrl+click)", mode = { "n", "x" } },
  { "<leader>jb", "<cmd>!gtags<cr>", desc = "Build gtags DB (cwd)" },
  { "<leader>jg", function() jump_to_definition(vim.fn.expand("<cword>")) end, desc = "Find global definition" },
  { "<leader>jg", function() jump_to_definition(selected_text()) end, desc = "Find global definition", mode = "x" },
}
for _, k in ipairs({
  { "<leader>js", "s", "Find this symbol" },
  { "<leader>jc", "c", "Find callers" },
  { "<leader>jt", "t", "Find this text string" },
  { "<leader>jf", "f", "Find file" },
  { "<leader>ji", "i", "Find files #including this" },
}) do
  vim.list_extend(keys, query_key(k[1], k[2], k[3]))
end

return {
  "dhananjaylatkar/cscope_maps.nvim",
  event = "VeryLazy",
  init = function()
    -- C identifiers are case-sensitive. With the default "followic" and
    -- LazyVim's ignorecase, the ctags fallback treats SSL_new and ssl_new as the
    -- same tag and stops to ask which one was meant.
    vim.opt.tagcase = "match"

    -- Shows which way global is being started, to tell a missing index from a
    -- global.exe whose output never reaches Neovim.
    vim.api.nvim_create_user_command("GtagsTransport", function(opts)
      local global = require("config.gtags_global")
      if opts.args == "reset" then
        global.reset()
      end
      vim.notify(global.status())
    end, { nargs = "?", complete = function() return { "reset" } end })
  end,
  keys = keys,
  opts = {
    disable_maps = true,
    cscope = {
      -- cscope_maps binds <C-]> to :Cstag from its own setup, which runs after
      -- the keys above and would win.
      tag = { keymap = false },
      db_file = "./GTAGS",
      exec = "gtags-cscope",
      picker = "snacks",
      skip_picker_for_single_result = true,
      project_rooter = {
        enable = true,
      },
    },
  },
}

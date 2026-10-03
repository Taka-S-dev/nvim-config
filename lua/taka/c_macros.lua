-- Macros and enum values told apart in C. The grammar colours both as a
-- constant when written in capitals, and a call to a function-like macro as a
-- call to a function; which one a name is, is known only where it is defined.
-- That is looked up in three places, in this order:
--
--   the file itself  its #defines and enum values, read from its syntax tree
--   the tags file    the kind ctags recorded for the name, d for a macro and
--                    e for an enum value, where the project has one
--                    (lua/plugins/gutentags.lua)
--   GTAGS            whether the line global says defines the name is a
--                    #define, for macros only (see from_gtags below)
--
-- and each use of the name on screen is coloured CMacro or CEnum. A name found
-- in none keeps the grammar's colour. The indexes are asked only about
-- names with a capital letter in them: a lowercase macro (min, likely) in one
-- file of a project would otherwise colour every variable of that name in all
-- the others. A name that is both, as `enum { A }; #define A A` makes it, is
-- a macro.
--
-- Only the lines on screen are looked at, when they are drawn, so a long file
-- costs no more than a short one.
local M = {}

local ns = vim.api.nvim_create_namespace("config_c_macros")

local DEFINED = [[
(preproc_def name: (identifier) @macro)
(preproc_function_def name: (identifier) @macro)
(enumerator name: (identifier) @enum)
]]
-- A macro can stand where a type does (`BOOL done;`), and is parsed as one.
local USED = "[(identifier) (type_identifier)] @name"
local GROUP = { macro = "CMacro", enum = "CEnum" }

local queries = {}
local function query(lang, text)
  local key = lang .. text
  if queries[key] == nil then
    local ok, parsed = pcall(vim.treesitter.query.parse, lang, text)
    queries[key] = ok and parsed or false
  end
  return queries[key]
end

-- The names each buffer defines itself, as of a changedtick.
local own = {}
-- Reading them takes the whole file, 20 ms at 10000 lines, too long for every
-- key typed: while the buffer changes, the last reading stands, and the file
-- is read again once it has been left alone this long.
local SETTLE = 300
local settle = {}

local function read(buf, parser)
  local names = {}
  local q = query(parser:lang(), DEFINED)
  for _, tree in ipairs(q and parser:trees() or {}) do
    for id, node in q:iter_captures(tree:root(), buf) do
      local ok, name = pcall(vim.treesitter.get_node_text, node, buf)
      if ok and names[name] ~= "macro" then
        names[name] = q.captures[id]
      end
    end
  end
  own[buf] = { tick = vim.api.nvim_buf_get_changedtick(buf), names = names }
  return names
end

local function redraw(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim__redraw({ buf = buf, valid = false })
  end
end

local function defined(buf, parser)
  local seen = own[buf]
  if not seen then
    return read(buf, parser)
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  -- Started again by a change, not by every redraw, or moving about the
  -- file would put the reading off for as long as the cursor moves.
  if seen.tick ~= tick and seen.waiting ~= tick then
    seen.waiting = tick
    settle[buf] = settle[buf] or vim.uv.new_timer()
    settle[buf]:start(
      SETTLE,
      0,
      vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(buf) and own[buf] then
          local ok, later = pcall(vim.treesitter.get_parser, buf)
          if ok and later then
            later:parse(true)
            read(buf, later)
            redraw(buf)
          end
        end
      end)
    )
  end
  return seen.names
end

-- What the tags file and GTAGS say of each name asked about, per buffer:
-- "macro", "enum", or false for neither. Dropped when either changes.
local tagged = {}
local asked = {}

local function gtags_root(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fs.root(name, "GTAGS") or nil
end

local function stamp(buf)
  return vim.api.nvim_buf_call(buf, function()
    local parts = {}
    for _, file in ipairs(vim.fn.tagfiles()) do
      parts[#parts + 1] = file .. "@" .. vim.fn.getftime(file)
    end
    local root = gtags_root(buf)
    if root then
      local gtags = vim.fs.joinpath(root, "GTAGS")
      parts[#parts + 1] = gtags .. "@" .. vim.fn.getftime(gtags)
    end
    return table.concat(parts, "|")
  end)
end

-- GTAGS, for the names the tags file did not place, as in a project indexed
-- by gtags alone (lua/taka/gtags/): global prints the line each name is
-- defined on, and a name defined by a #define is a macro. An enum value is
-- not told from its line, which may hold the whole enum or the value alone,
-- and keeps the grammar's colour, the one an enum value in capitals gets
-- anyway. One query runs at a time, for up to BATCH names, and none where no
-- GTAGS covers the file.
local BATCH = 200
local waiting = {}
local running = {}

local function from_gtags(buf)
  if running[buf] or not waiting[buf] or next(waiting[buf]) == nil then
    return
  end
  local root = gtags_root(buf)
  if not root or vim.fn.executable("global") == 0 then
    waiting[buf] = nil
    return
  end
  local names = {}
  for name in pairs(waiting[buf]) do
    names[#names + 1] = name
    waiting[buf][name] = nil
    if #names == BATCH then
      break
    end
  end
  running[buf] = true
  -- Through ask, as a query for names may rightly find none, and in patterns
  -- short enough for global.
  require("taka.lib.gtags_global").ask_names(root, { "-x", "-d" }, names, function(output)
    running[buf] = nil
    local known = tagged[buf]
    if not known or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local found = false
    for line in (output or ""):gmatch("[^\r\n]+") do
      local name = line:match("^(%S+)")
      if name and known.names[name] == false and line:find("#%s*define%s+" .. name .. "%f[^%w_]") then
        known.names[name] = "macro"
        found = true
      end
    end
    if found then
      redraw(buf)
    end
    from_gtags(buf)
  end)
end

-- The names waiting for the tags file, asked outside the redraw that met them.
local function look_up(buf)
  local names = asked[buf]
  asked[buf] = nil
  if not names or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local known = tagged[buf]
  known.stamp = known.stamp or stamp(buf)
  local found = false
  vim.api.nvim_buf_call(buf, function()
    -- Case matters to C: MAX and max are two names.
    local case = vim.bo.tagcase
    vim.bo.tagcase = "match"
    for name in pairs(names) do
      local kind = false
      for _, tag in ipairs(vim.fn.taglist("^" .. name .. "$")) do
        if tag.name == name then
          if tag.kind == "d" or tag.kind == "macro" then
            kind = "macro"
            break
          elseif tag.kind == "e" or tag.kind == "enumerator" then
            kind = "enum"
          end
        end
      end
      known.names[name] = kind
      found = found or kind ~= false
      if not kind then
        waiting[buf] = waiting[buf] or {}
        waiting[buf][name] = true
      end
    end
    vim.bo.tagcase = case
  end)
  if found then
    redraw(buf)
  end
  from_gtags(buf)
end

local function ask(buf, name)
  if not asked[buf] then
    asked[buf] = {}
    vim.schedule(function()
      look_up(buf)
    end)
  end
  asked[buf][name] = true
end

-- The tags files and GTAGS looked at again, and what was learnt from them
-- dropped if one was written since.
function M.recheck(buf)
  if not (tagged[buf] and tagged[buf].stamp) then
    return
  end
  local now = stamp(buf)
  if now ~= tagged[buf].stamp then
    tagged[buf] = { stamp = now, names = {} }
    waiting[buf] = nil
    redraw(buf)
  end
end

-- The uses of macros and enum values on rows top to bot (0-based, inclusive),
-- by row: { first column, end column, group }. Names not yet looked up in the
-- indexes are asked about, and coloured once the answer is in.
function M.marks(buf, top, bot)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser or #parser:trees() == 0 then
    return nil
  end
  local q = query(parser:lang(), USED)
  if not q then
    return nil
  end
  local names = defined(buf, parser)
  -- The stamp is taken with the first answer, outside the redraw.
  tagged[buf] = tagged[buf] or { names = {} }
  local known = tagged[buf].names
  local rows, any = {}, false
  for _, tree in ipairs(parser:trees()) do
    for _, node in q:iter_captures(tree:root(), buf, top, bot + 1) do
      local got, name = pcall(vim.treesitter.get_node_text, node, buf)
      if got then
        local kind = names[name]
        if not kind and name:find("%u") then
          kind = known[name]
          if kind == nil then
            ask(buf, name)
          end
        end
        if kind then
          local row, col, _, end_col = node:range()
          rows[row] = rows[row] or {}
          table.insert(rows[row], { col, end_col, GROUP[kind] })
          any = true
        end
      end
    end
  end
  return any and rows or nil
end

-- What each window is to show, from its on_win to its on_line calls.
local drawing = {}

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, win, buf, top, bot)
    drawing[win] = nil
    if vim.bo[buf].filetype ~= "c" then
      return false
    end
    drawing[win] = M.marks(buf, top, bot)
    return drawing[win] ~= nil
  end,
  on_line = function(_, win, buf, row)
    local marks = drawing[win] and drawing[win][row]
    for _, mark in ipairs(marks or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, row, mark[1], {
        end_col = mark[2],
        hl_group = mark[3],
        ephemeral = true,
        -- Over the grammar's colours, which are drawn at 100.
        priority = 125,
      })
    end
  end,
})

local group = vim.api.nvim_create_augroup("config_c_macros", { clear = true })

-- Colours for a colour scheme that has none of its own for these.
local function defaults()
  vim.api.nvim_set_hl(0, "CMacro", { link = "@constant.macro", default = true })
  vim.api.nvim_set_hl(0, "CEnum", { link = "@constant", default = true })
end
defaults()
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = defaults })

-- A tags file is rewritten after a save (gutentags), and may have been by
-- another editor while this one was away.
vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "BufWritePost" }, {
  group = group,
  callback = function(ev)
    M.recheck(ev.buf)
  end,
})
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "GutentagsUpdated",
  callback = function()
    for buf in pairs(tagged) do
      if vim.api.nvim_buf_is_valid(buf) then
        M.recheck(buf)
      end
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(ev)
    if settle[ev.buf] then
      settle[ev.buf]:stop()
      settle[ev.buf]:close()
    end
    own[ev.buf], tagged[ev.buf], asked[ev.buf], settle[ev.buf] = nil, nil, nil, nil
    waiting[ev.buf], running[ev.buf] = nil, nil
  end,
})

return M

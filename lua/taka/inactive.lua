-- The blocks of C that #if, #ifdef and their kin leave out, drawn grey, for
-- macros set by hand for the session (<leader>cp, :Defines): what a build
-- with CONFIG_X on and OLD_API off would see is read without the rest in the
-- way. The macro values a real build takes come from its makefiles and
-- headers, which are not read; a condition that names a macro not set is
-- left as it is, as a guess of false would grey code that does run. `#if 0`
-- is grey with nothing set.
local M = {}

-- The macros set: a name to its value ("1" for one set with none), or false
-- for one known not to be defined.
M.defines = {}

-- Bumped when the macros change, so the blocks of every buffer are worked
-- out again.
local version = 0

local NAME = "^[%a_][%w_]*$"

-- Every buffer drawn again with the macros as they are now.
local function changed()
  version = version + 1
  vim.cmd("redraw!")
end

-- The macros as typed: `NAME`, `NAME=value`, and `!NAME` for one not
-- defined, separated by spaces.
function M.text()
  local words = {}
  for name, value in pairs(M.defines) do
    words[#words + 1] = value == false and ("!" .. name) or value == "1" and name or (name .. "=" .. value)
  end
  table.sort(words, function(a, b)
    return a:gsub("^!", "") < b:gsub("^!", "")
  end)
  return table.concat(words, " ")
end

-- Sets the macros from their text; returns nil and what is wrong on a word
-- that is not a name, and leaves the macros as they were.
function M.set(text)
  local defines = {}
  for word in vim.trim(text or ""):gmatch("%S+") do
    local name, value = word:match("^([^=]+)=(.*)$")
    local undefined = word:match("^!(.+)$")
    name = undefined or name or word
    if not name:match(NAME) then
      return nil, "not a macro name: " .. word
    end
    defines[name] = not undefined and (value and value ~= "" and value or "1")
  end
  M.defines = defines
  changed()
  return true
end

-- Sets one macro: its value, false for not defined, or nil for not set.
function M.put(name, value)
  M.defines[name] = value
  changed()
end

-- What one macro goes to next in the list: not set, defined, not defined,
-- and round again.
function M.cycle(name)
  local value = M.defines[name]
  if value == nil then
    M.put(name, "1")
  elseif value == false then
    M.put(name, nil)
  else
    M.put(name, false)
  end
end

-- The truth of a condition of #if or #elif: true, false, or nil when it
-- names a macro not set, or is not worked out. `defined` is answered from the
-- macros set; another name is replaced by its value, and a name known not to
-- be defined is 0, as C has it.
local function truth(condition)
  local unknown = false
  local function known(name)
    local value = M.defines[name]
    if value == nil then
      unknown = true
      return "0"
    end
    return value
  end
  local expr = condition:gsub("/%*.-%*/", " "):gsub("//.*$", "")
  expr = expr:gsub("defined%s*%(%s*([%a_][%w_]*)%s*%)", function(name)
    return known(name) == false and "0" or "1"
  end)
  expr = expr:gsub("defined%s+([%a_][%w_]*)", function(name)
    return known(name) == false and "0" or "1"
  end)
  -- A name starts after no letter or digit: the U of 10UL and the x of 0x1F
  -- are parts of numbers.
  expr = expr:gsub("%f[%w_][%a_][%w_]*", function(name)
    local value = known(name)
    if value == false then
      return "0"
    end
    return value
  end)
  if unknown then
    return nil
  end
  local value = require("taka.radix").evaluate(expr)
  if value == nil then
    return nil
  end
  return value ~= 0
end

-- The truth of a directive's condition, by its kind.
local function condition_of(kind, rest)
  if kind == "ifdef" or kind == "elifdef" or kind == "ifndef" or kind == "elifndef" then
    local name = rest:match("^([%a_][%w_]*)")
    local value = name and M.defines[name]
    if value == nil then
      return nil
    end
    local is = value ~= false
    if kind:find("ndef") then
      return not is
    end
    return is
  end
  return truth(rest)
end

-- The directives that open a block, and those that start its next branch.
local OPEN = { ["if"] = true, ifdef = true, ifndef = true }
local NEXT = { elif = true, elifdef = true, elifndef = true, ["else"] = true }

-- The line at `row`, with the lines after it a directive is continued over
-- with backslashes, as one; and the row it ends on.
local function joined(lines, row)
  local line = lines[row]
  while line:match("^%s*#") and line:match("\\%s*$") and row < #lines do
    row = row + 1
    line = line:gsub("\\%s*$", " ") .. lines[row]
  end
  return row, line
end

-- The macros the conditions of `lines` name, in the order they first come,
-- each with the number of directives that name it.
function M.names(lines)
  local out, seen = {}, {}
  local row = 1
  while row <= #lines do
    local line
    row, line = joined(lines, row)
    local kind, rest = line:match("^%s*#%s*(%a+)%s*(.*)$")
    if OPEN[kind] or NEXT[kind] then
      rest = rest:gsub("/%*.-%*/", " "):gsub("//.*$", "")
      if kind:find("def") then
        rest = rest:match("^([%a_][%w_]*)") or ""
      end
      local here = {}
      for name in rest:gmatch("%f[%w_][%a_][%w_]*") do
        if name ~= "defined" and not here[name] then
          here[name] = true
          if not seen[name] then
            seen[name] = { name = name, uses = 0 }
            out[#out + 1] = seen[name]
          end
          seen[name].uses = seen[name].uses + 1
        end
      end
    end
    row = row + 1
  end
  return out
end

-- The rows (0-based) of `lines` left out by the macros set, as a set. A
-- branch is true, false or not known; a row is left out when a branch it is
-- in is false. Once a branch is taken, those after it are false; once one is
-- not known, those after it are not known either, unless false on their own.
-- A directive's own line goes with the block around it: `#else` stays plain
-- when it ends a false branch, so where the grey stops is seen.
function M.rows(lines)
  local out, stack = {}, {}
  local function any_false(upto)
    for i = 1, upto do
      if stack[i].status == false then
        return true
      end
    end
    return false
  end
  local row = 1
  while row <= #lines do
    local first, line = row, nil
    row, line = joined(lines, row)
    local kind, rest = line:match("^%s*#%s*(%a+)%s*(.*)$")
    local frame = stack[#stack]
    local grey
    if OPEN[kind] then
      grey = any_false(#stack)
      local c = condition_of(kind, rest)
      stack[#stack + 1] = { status = c, taken = c == true and "yes" or c == nil and "maybe" or "no" }
    elseif frame and NEXT[kind] then
      grey = any_false(#stack - 1)
      local c = kind == "else" or condition_of(kind, rest)
      if frame.taken == "yes" or c == false then
        frame.status = false
      elseif frame.taken == "maybe" then
        frame.status = nil
      else
        frame.status = c
        frame.taken = c == true and "yes" or "maybe"
      end
    elseif frame and kind == "endif" then
      grey = any_false(#stack - 1)
      stack[#stack] = nil
    else
      grey = any_false(#stack)
    end
    if grey then
      for r = first, row do
        out[r - 1] = true
      end
    end
    row = row + 1
  end
  return out
end

-- The rows left out of a buffer, worked out again only when it or the
-- macros change.
local cache = {}
local function rows_of(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local kept = cache[buf]
  if kept and kept.tick == tick and kept.version == version then
    return kept.rows
  end
  local rows = M.rows(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  cache[buf] = { tick = tick, version = version, rows = rows }
  return rows
end

local filetypes = { c = true, cpp = true }

-- Grey for the text only, the background left as it is, so a word lit there
-- still shows; above the colours of the syntax, of the language server's
-- words (125 to 127) and of lua/taka/c_macros.lua (125), which would
-- otherwise leave a macro or a function in its colour in the grey.
local function colour()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "PreprocInactive", { fg = comment.fg, default = true })
end
colour()
vim.api.nvim_create_autocmd("ColorScheme", { callback = colour })

local namespace = vim.api.nvim_create_namespace("taka.inactive")
local drawing = {}
vim.api.nvim_set_decoration_provider(namespace, {
  on_win = function(_, _, buf)
    if not filetypes[vim.bo[buf].filetype] then
      return false
    end
    drawing[buf] = rows_of(buf)
    return next(drawing[buf]) ~= nil
  end,
  on_line = function(_, _, buf, row)
    if drawing[buf] and drawing[buf][row] then
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = "PreprocInactive",
        ephemeral = true,
        priority = 130,
      })
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(args)
    cache[args.buf] = nil
    drawing[args.buf] = nil
  end,
})

-- The rows of the list of macros: those the conditions of `buf` name, in the
-- order they come, then those set that it does not name.
function M.items(buf)
  local lines = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
  local out, named = {}, {}
  for _, entry in ipairs(M.names(lines)) do
    named[entry.name] = true
    out[#out + 1] = { name = entry.name, uses = entry.uses }
  end
  local others = {}
  for name in pairs(M.defines) do
    if not named[name] then
      others[#others + 1] = name
    end
  end
  table.sort(others)
  for _, name in ipairs(others) do
    out[#out + 1] = { name = name, uses = 0 }
  end
  for index, item in ipairs(out) do
    item.idx, item.text = index, item.name
  end
  return out
end

local MARK = {
  on = { "✓ ", "DiagnosticOk" },
  off = { "✗ ", "DiagnosticError" },
  unset = { "· ", "Comment" },
}

-- The macros of the file in a list at the bottom, the code above greyed again
-- as each is changed: Enter goes from not set to defined to not defined, a
-- name typed that is not in the list is added as defined, <C-e> gives one a
-- value, and <C-x> leaves one not set.
function M.ask()
  local buf = vim.api.nvim_get_current_buf()
  local function count()
    return vim.tbl_count(M.defines)
  end
  local function title()
    return ("Macros for #if (%d set)  Enter: on / off / unset"):format(count())
  end
  -- The list read again with the cursor kept on `name`.
  local function again(picker, name)
    picker.title = title()
    picker:update_titles()
    local index
    for i, item in ipairs(M.items(buf)) do
      if item.name == name then
        index = i
      end
    end
    require("taka.lib.sidebar").refresh(picker, index, function(item)
      return item.name == name
    end)
  end
  Snacks.picker({
    source = "inactive_macros",
    title = title(),
    layout = { preset = "ivy", preview = false, layout = { height = 0.3 } },
    finder = function()
      return M.items(buf)
    end,
    format = function(item)
      local value = M.defines[item.name]
      local mark = value == nil and MARK.unset or value == false and MARK.off or MARK.on
      local out = { { mark[1], mark[2] }, { item.name, value == nil and "Comment" or nil } }
      if value and value ~= "1" then
        out[#out + 1] = { " = " .. value, "Number" }
      end
      out[#out + 1] = { item.uses > 0 and ("  %d×"):format(item.uses) or "  not in this file", "Comment" }
      return out
    end,
    confirm = function(picker, item)
      if item then
        M.cycle(item.name)
        return again(picker, item.name)
      end
      local typed = vim.trim(picker.input:get())
      if typed:match(NAME) then
        M.put(typed, "1")
        picker.input:set("")
        return again(picker, typed)
      end
    end,
    actions = {
      macro_value = function(picker, item)
        if not item then
          return
        end
        local now = M.defines[item.name]
        vim.ui.input({ prompt = "Value of " .. item.name .. ": ", default = now or "1" }, function(text)
          if text and vim.trim(text) ~= "" then
            M.put(item.name, vim.trim(text))
          end
          if not picker.closed then
            again(picker, item.name)
          end
        end)
      end,
      macro_unset = function(picker, item)
        local items = picker:selected({ fallback = true })
        picker.list:set_selected()
        for _, it in ipairs(items) do
          M.defines[it.name] = nil
        end
        changed()
        again(picker, item and item.name)
      end,
    },
    win = {
      input = {
        keys = {
          ["<c-e>"] = { "macro_value", mode = { "n", "i" }, desc = "Give the macro a value" },
          ["<c-x>"] = { "macro_unset", mode = { "n", "i" }, desc = "Leave the macro not set" },
        },
      },
      list = {
        keys = {
          ["e"] = { "macro_value", desc = "Give the macro a value" },
          ["dd"] = { "macro_unset", desc = "Leave the macro not set (Tab marks several)" },
        },
      },
    },
  })
end

vim.api.nvim_create_user_command("Defines", function(command)
  if command.args == "" then
    vim.notify(M.text() ~= "" and ("Macros: " .. M.text()) or "No macros set")
    return
  end
  local ok, err = M.set(command.args)
  if not ok then
    vim.notify(err, vim.log.levels.WARN)
  end
end, { nargs = "*", desc = "Macros for the session, to grey what #if leaves out: NAME NAME=value !NAME" })

return M

-- The value of a macro of C, worked out from its #define and those of the
-- macros in it, for <leader>cb (lua/taka/radix.lua) on a name or on an
-- expression with names in it. A mask is mostly used by its name,
-- `flags & SSL_OP_NO_SSL_MASK`, and its value was found by reading one
-- #define after another and adding them up by hand.
--
-- The definitions come from GTAGS, as a jump finds them; the arithmetic is
-- radix's. Only a macro that is a number at heart is worked out: one that
-- takes arguments, or is no #define, an enum value, is said to be so. A name
-- defined more than once, under #ifdef, has a value for each definition, and
-- they are all shown: which one a build takes is not to be known from here,
-- and one picked would be a value that looks right and may not be.
local M = {}

local radix = require("taka.radix")

-- Macros within macros are followed this many levels down.
local DEPTH = 8

-- Words that make up a cast of C's own types, `(unsigned long)` and the like,
-- which the arithmetic of 64 bits leaves out.
local TYPES = {
  unsigned = true,
  signed = true,
  long = true,
  int = true,
  short = true,
  char = true,
  size_t = true,
  ssize_t = true,
  const = true,
}

local function is_type(word)
  return TYPES[word] or word:match("^u?int%d+_t$") or word:match("^__[us]%d+$") or word:match("^[us]%d+$")
end

local function strip_casts(text)
  return (
    text:gsub("%(%s*([%a_][%w_%s%*]-)%s*%)", function(inside)
      for word in inside:gmatch("[%a_][%w_]*") do
        if not is_type(word) then
          return nil
        end
      end
      return ""
    end)
  )
end

-- The names in `text`, each once; a suffix of a number, the UL of 0xffUL, is
-- none, nor is a word of a cast.
local function names_in(text)
  local out, seen = {}, {}
  for at, word in text:gmatch("()([%a_][%w_]*)") do
    if not text:sub(at - 1, at - 1):match("[%w_]") and not is_type(word) and not seen[word] then
      seen[word] = true
      out[#out + 1] = word
    end
  end
  return out
end

-- `text` with each name in `values` put in brackets for its value, so a value
-- that is itself an expression keeps its place in the one around it.
local function substitute(text, values)
  return (
    text:gsub("()([%a_][%w_]*)", function(at, word)
      if values[word] and not text:sub(at - 1, at - 1):match("[%w_]") then
        return "(" .. values[word] .. ")"
      end
    end)
  )
end

-- The body of the #define of `name` near line `lnum` of `lines`: the line
-- GTAGS gives, else the nearest that defines it, as an edit since GTAGS was
-- built moves it; its lines joined where they end in a backslash, and the
-- comments left out. Or nil and why there is none.
local function body_of(lines, name, lnum)
  local pattern = "^%s*#%s*define%s+" .. name .. "%f[^%w_]()"
  local after = lines[lnum] and lines[lnum]:match(pattern)
  local at = after and lnum
  if not at then
    for i, line in ipairs(lines) do
      local found = line:match(pattern)
      if found and (not at or math.abs(i - lnum) < math.abs(at - lnum)) then
        at, after = i, found
      end
    end
  end
  if not at then
    return nil, "is not a #define (an enum value, a variable or a function?)"
  end
  local rest = lines[at]:sub(after)
  if rest:sub(1, 1) == "(" then
    return nil, "takes arguments"
  end
  local parts = {}
  while rest and rest:match("\\%s*$") do
    parts[#parts + 1] = rest:gsub("\\%s*$", "")
    at = at + 1
    rest = lines[at]
  end
  parts[#parts + 1] = rest or ""
  local body = table.concat(parts, " "):gsub("/%*.-%*/", " "):gsub("//.*$", "")
  body = vim.trim(body:gsub("%s+", " "))
  if body == "" then
    return nil, "is defined empty"
  end
  return body
end

-- The definitions of `names` and of the names in theirs, as far as DEPTH,
-- read from GTAGS and the files: a table of name to its definitions, each
-- { file, lnum, body } or { file, lnum, err }.
local function gather(root, names, done)
  local known, lines_of = {}, {}
  local function step(asked, depth)
    local todo = vim.tbl_filter(function(name)
      return not known[name]
    end, asked)
    if #todo == 0 or depth > DEPTH then
      return done(known)
    end
    for _, name in ipairs(todo) do
      known[name] = {}
    end
    require("taka.lib.gtags_global").ask_names(root, { "--result=ctags", "-a", "-d" }, todo, function(output)
      local next_names = {}
      for line in (output or ""):gmatch("[^\r\n]+") do
        local name, file, lnum = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
        if name and known[name] then
          if not lines_of[file] then
            local ok, read = pcall(vim.fn.readfile, file)
            lines_of[file] = ok and read or {}
          end
          local body, err = body_of(lines_of[file], name, tonumber(lnum))
          err = err and name .. " " .. err
          table.insert(known[name], { file = file, lnum = tonumber(lnum), body = body, err = err })
          vim.list_extend(next_names, body and names_in(strip_casts(body)) or {})
        end
      end
      step(next_names, depth + 1)
    end)
  end
  step(names, 1)
end

-- The values `name` has, one for each of its definitions: { def, v, how } or
-- { def, err }.
local function values_of(known, name, chain)
  if chain[name] then
    return { { err = name .. " refers to itself" } }
  end
  local defs = known[name]
  if not defs then
    return { { err = name .. " lies deeper than " .. DEPTH .. " macros" } }
  end
  if #defs == 0 then
    return { { err = name .. " is not defined in GTAGS (an enum value or a variable?)" } }
  end
  chain[name] = true
  local out = {}
  for _, def in ipairs(defs) do
    local result = { def = def, err = def.err }
    if def.body then
      local expression = strip_casts(def.body)
      local values = {}
      for _, inner in ipairs(names_in(expression)) do
        local value, err = M.single(values_of(known, inner, chain), inner)
        if not value then
          result.err = err
          break
        end
        values[inner] = tostring(value):gsub("ULL$", "")
      end
      if not result.err then
        result.v, result.how = radix.evaluate(substitute(expression, values))
        result.err = not result.v and name .. " is no number: " .. def.body or nil
      end
    end
    out[#out + 1] = result
  end
  chain[name] = nil
  return out
end

-- The one value the values of `name` come to, with how it was worked out, or
-- nil and why: one has none, or the definitions differ.
function M.single(values, name)
  local value, how, first_err
  for _, result in ipairs(values) do
    if not result.v then
      first_err = first_err or result.err
    elseif value and value ~= result.v then
      return nil, name .. " has " .. #values .. " definitions that differ"
    elseif not value then
      value, how = result.v, result.how
    end
  end
  if first_err or not value then
    return nil, first_err
  end
  return value, nil, how
end

local function short(text, width)
  return #text > width and text:sub(1, width - 1) .. "…" or text
end

-- The parts of `text` joined by its outermost |, as flags are put together:
-- `(21|BIO_TYPE_SOURCE_SINK|BIO_TYPE_DESCRIPTOR)` is 21 and the two names, and
-- `((1 << 4) | FLAG)` is `(1 << 4)` and FLAG, the 1 and the 4 no parts of
-- their own. Nil when there are not two: no | at the top, or only ||.
local function or_parts(text)
  text = vim.trim(text)
  -- Brackets around the whole, as #define puts them, taken off.
  while text:sub(1, 1) == "(" do
    local depth, closes = 0, nil
    for i = 1, #text do
      local c = text:sub(i, i)
      depth = depth + (c == "(" and 1 or c == ")" and -1 or 0)
      if depth == 0 then
        closes = i
        break
      end
    end
    if closes ~= #text then
      break
    end
    text = vim.trim(text:sub(2, -2))
  end
  local parts, depth, from = {}, 0, 1
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    elseif c == "|" and depth == 0 then
      if text:sub(i + 1, i + 1) == "|" then
        return nil
      end
      parts[#parts + 1] = vim.trim(text:sub(from, i - 1))
      from = i + 1
    end
    i = i + 1
  end
  parts[#parts + 1] = vim.trim(text:sub(from))
  return #parts >= 2 and parts or nil
end

-- What one part comes to: a name's single value, or the part worked out with
-- the names in it put in for theirs; or nil and why not.
local function value_of_part(known, part)
  if part:match("^[%a_][%w_]*$") then
    return M.single(values_of(known, part, {}), part)
  end
  local values = {}
  for _, name in ipairs(names_in(part)) do
    local value, err = M.single(values_of(known, name, {}), name)
    if not value then
      return nil, err
    end
    values[name] = tostring(value):gsub("ULL$", "")
  end
  local v, how = radix.evaluate(substitute(part, values))
  if not v then
    return nil, "is no number"
  end
  return v, nil, how
end

-- Where the bits of `text` come from, a part a line with the values in a
-- column: the parts joined by its outermost |, else the names written in it,
-- each worked out to the bottom already; one of them looked into is one
-- <leader>cb away. A part with no value says why, and shows where the working
-- out stopped; whether one did is the second value.
local BREAKDOWN = 12

local function breakdown(known, text)
  local parts = or_parts(strip_casts(text)) or names_in(strip_casts(text))
  local width = 0
  for _, part in ipairs(parts) do
    width = math.max(width, #part)
  end
  local rows, stopped, digits = {}, false, 2
  for i, part in ipairs(parts) do
    if i > BREAKDOWN then
      break
    end
    local value, err, how = value_of_part(known, part)
    stopped = stopped or not value
    local shown = value and radix.brief(value, how) or err:gsub("^" .. vim.pesc(part) .. " ", "")
    rows[#rows + 1] = { part = part, shown = shown }
    if shown:match("^0x") then
      digits = math.max(digits, #shown - 2)
    end
  end
  -- Hex of one width, that of a C integer, so the bits line up in a column.
  digits = digits <= 2 and 2 or digits <= 4 and 4 or digits <= 8 and 8 or 16
  local out = {}
  for _, row in ipairs(rows) do
    local shown = row.shown:gsub("^0x(%x+)$", function(hex)
      return "0x" .. ("0"):rep(digits - #hex) .. hex
    end)
    out[#out + 1] = "  " .. row.part .. (" "):rep(width - #row.part) .. "  " .. shown
  end
  if #parts > BREAKDOWN then
    out[#out + 1] = ("  … and %d more"):format(#parts - BREAKDOWN)
  end
  return out, stopped
end

-- The lines that show what `text`, a name or an expression with names in it,
-- comes to, given the definitions gathered.
function M.lines(text, known, root)
  if text:match("^[%a_][%w_]*$") then
    local values = values_of(known, text, {})
    local value, err = M.single(values, text)
    local def = values[1] and values[1].def
    local out, stopped = { text }, false
    if def and def.body then
      out[#out + 1] = "= " .. short(def.body, 60)
      local rows
      rows, stopped = breakdown(known, def.body)
      vim.list_extend(out, rows)
    end
    if value then
      vim.list_extend(out, radix.format(value, values[1].how))
      return out
    end
    if #values < 2 or not err:find("differ", 1, true) then
      -- Said already by the name it stopped at.
      if not stopped then
        out[#out + 1] = err
      end
      return out
    end
    -- Each definition and its value, as the build that takes it would have.
    out = { text .. "  (" .. #values .. " definitions)" }
    for _, result in ipairs(values) do
      local where = vim.fs.normalize(result.def.file):gsub("^" .. vim.pesc(vim.fs.normalize(root)) .. "/", "")
      -- Decimal and hex only: a row each would hide which file is which.
      local rows = result.v and radix.format(result.v, result.how)
      local shown = rows and table.concat({ rows[1], rows[2] }, "  ") or result.err
      out[#out + 1] = ("%s:%d  %s"):format(where, result.def.lnum, shown)
    end
    return out
  end
  local out = { text }
  local rows, stopped = breakdown(known, text)
  vim.list_extend(out, rows)
  local values = {}
  for _, name in ipairs(names_in(strip_casts(text))) do
    local value, err = M.single(values_of(known, name, {}), name)
    if not value then
      if not stopped then
        out[#out + 1] = err
      end
      return out
    end
    values[name] = tostring(value):gsub("ULL$", "")
  end
  local v, how = radix.evaluate(substitute(strip_casts(text), values))
  if not v then
    out[#out + 1] = "is no expression of numbers"
    return out
  end
  vim.list_extend(out, radix.format(v, how))
  return out
end

-- Works out `text` and shows it by the cursor, if the cursor is still where
-- it was asked from when GTAGS has answered.
function M.show(text)
  local file = vim.api.nvim_buf_get_name(0)
  local root = require("taka.lib.gtags_global").root(file)
  if not root then
    return vim.notify("No GTAGS to find " .. text .. " in. Build one with <leader>jb.", vim.log.levels.WARN)
  end
  local buf, at = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  gather(root, names_in(strip_casts(text)), function(known)
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() ~= buf or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), at) then
        return
      end
      radix.show_lines(M.lines(text, known, root))
    end)
  end)
end

-- For the checks: the definitions of the names in `text` gathered, then `done`
-- given its lines.
function M.work_out(text, root, done)
  gather(root, names_in(strip_casts(text)), function(known)
    done(M.lines(text, known, root))
  end)
end

return M

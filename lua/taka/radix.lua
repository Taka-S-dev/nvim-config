-- A number in C, in every base at once (<leader>cb): the integer or character
-- literal under the cursor, or the expression selected, in decimal, hex and
-- binary, with the bits it sets. Reading flags and masks, `0x20000000U` or
-- `flags & 0x0C`, took a calculator, or :lua with the digits typed again, and
-- a zero miscounted in a mask of thirty bits is the usual slip.
--
-- Values are 64-bit unsigned integers of LuaJIT: a Lua number holds 53 bits,
-- and masks of 64 bits are common. An expression is worked out as C does it,
-- its operators bound as tightly as in C, so `1 & 2 == 2` is `1 & (2 == 2)`.
local M = {}

local bit = require("bit")

local ONE = 1ULL

-- The digits of `s` in groups of `size` from the right, with `sep` between:
-- 4294967295 as 4,294,967,295.
local function group(s, size, sep)
  local out = {}
  for i = 1, #s do
    if i > 1 and (#s - i + 1) % size == 0 then
      out[#out + 1] = sep
    end
    out[#out + 1] = s:sub(i, i)
  end
  return table.concat(out)
end

local function decimal(v)
  return (tostring(v):gsub("ULL$", ""))
end

local function hex(v)
  return "0x" .. (bit.tohex(v, 16):gsub("^0+(.)", "%1"))
end

-- The highest bit set, counted from 0, or -1 for 0.
local function top_bit(v)
  for i = 63, 0, -1 do
    if bit.band(bit.rshift(v, i), ONE) == ONE then
      return i
    end
  end
  return -1
end

-- Binary padded to the width of a C integer, 8, 16, 32 or 64 digits, so the
-- place of a bit can be read off the number of digits, in groups of four.
local function binary(v)
  local digits = top_bit(v) + 1
  local width = digits <= 8 and 8 or digits <= 16 and 16 or digits <= 32 and 32 or 64
  local out = {}
  for i = width - 1, 0, -1 do
    out[#out + 1] = tostring(tonumber(bit.band(bit.rshift(v, i), ONE)))
  end
  return "0b" .. group(table.concat(out), 4, "_")
end

-- The bits set, the highest first as the binary reads, "6, 1 set (0=LSB)";
-- past a dozen, how many.
local function bits_set(v)
  local bits = {}
  for i = 63, 0, -1 do
    if bit.band(bit.rshift(v, i), ONE) == ONE then
      bits[#bits + 1] = tostring(i)
    end
  end
  if #bits > 12 then
    return #bits .. " bits set"
  end
  return table.concat(bits, ", ") .. " set (0=LSB)"
end

-- The digits of `digits` in base `base` as a 64-bit value, or nil past 64 bits.
local function value_of(digits, base)
  local v = 0ULL
  local limit = bit.bnot(0ULL)
  for i = 1, #digits do
    local d = tonumber(digits:sub(i, i), 16)
    if v > (limit - d) / base then
      return nil
    end
    v = v * base + d
  end
  return v
end

-- An integer literal of C: its value and base, or nil for one C has not, such
-- as 089, or one past 64 bits. The suffixes, U, L and their mixes, are dropped.
function M.parse(text)
  local number = text:gsub("[uUlL]+$", "")
  local digits = number:match("^0[xX](%x+)$")
  if digits then
    return value_of(digits, 16), 16
  end
  digits = number:match("^0[bB]([01]+)$")
  if digits then
    return value_of(digits, 2), 2
  end
  if number:match("^0[0-7]+$") then
    return value_of(number:sub(2), 8), 8
  end
  if number:match("^%d+$") and not number:match("^0%d") then
    return value_of(number, 10), 10
  end
end

local ESCAPES = { ["0"] = 0, a = 7, b = 8, f = 12, n = 10, r = 13, t = 9, v = 11 }

-- The code of a character literal, 'A' or '\n', or nil for one past ASCII:
-- its bytes go by the file's encoding.
local function char_code(text)
  local inner = text:sub(2, -2)
  local escaped = inner:match("^\\(.+)$")
  local code
  if not escaped then
    code = inner:byte()
  elseif escaped:match("^x%x+$") then
    code = tonumber(escaped:sub(2), 16)
  elseif escaped:match("^[0-7]+$") then
    code = tonumber(escaped, 8)
  else
    code = ESCAPES[escaped] or escaped:byte()
  end
  return code and code < 128 and code or nil
end

-- The literal that column `col` (1-based) of `line` is on: its text and where
-- it starts and ends, or nil. A number joined to a name or a point, as in
-- `var2`, `1.5` or `1e5`, is no literal of its own.
function M.literal_at(line, col)
  local i = 1
  while i <= #line do
    local text = line:match("^'\\x%x+'", i)
      or line:match("^'\\[0-7][0-7]?[0-7]?'", i)
      or line:match("^'\\.'", i)
      or line:match("^'[^'\\]'", i)
    if not text and line:sub(i, i):match("%d") and not line:sub(i - 1, i - 1):match("[%w_.]") then
      text = (line:match("^0[xX]%x+", i) or line:match("^0[bB][01]+", i) or line:match("^%d+", i))
      text = text .. (line:match("^[uUlL]*", i + #text) or "")
      if line:sub(i + #text, i + #text):match("[%w_.]") then
        text = nil
      end
    end
    if text then
      local last = i + #text - 1
      if i <= col and col <= last then
        return text, i, last
      end
      i = last + 1
    else
      i = i + 1
    end
  end
end

-- The lines that show a value: decimal, hex, binary and the bits set.
local function rows(v)
  local out = {
    "dec  " .. group(decimal(v), 3, ","),
    "hex  " .. hex(v),
    "bin  " .. binary(v),
  }
  if v ~= 0ULL then
    out[#out + 1] = "bit  " .. bits_set(v)
  end
  return out
end

-- What a literal is, as lines, or nil when it is none C has.
function M.describe(text)
  if text:sub(1, 1) == "'" then
    local code = char_code(text)
    return code and { text, "dec  " .. code, "hex  " .. hex(code + 0ULL) } or nil
  end
  local v, base = M.parse(text)
  if not v then
    return nil
  end
  -- 010 read as ten is a slip of C's own: a leading zero makes it octal.
  local out = { base == 8 and text .. "  (octal)" or text }
  vim.list_extend(out, rows(v))
  return out
end

-- How tightly each operator binds, as in C, loosest first.
local PRECEDENCE = {
  ["|"] = 1,
  ["^"] = 2,
  ["&"] = 3,
  ["=="] = 4,
  ["!="] = 4,
  ["<"] = 5,
  ["<="] = 5,
  [">"] = 5,
  [">="] = 5,
  ["<<"] = 6,
  [">>"] = 6,
  ["+"] = 7,
  ["-"] = 7,
  ["*"] = 8,
  ["/"] = 8,
  ["%"] = 8,
}

local function tokens(source)
  local out, i = {}, 1
  while i <= #source do
    local space = source:match("^%s+", i)
    local number = not space
      and (
        source:match("^0[xX]%x+[uUlL]*", i)
        or source:match("^0[bB][01]+[uUlL]*", i)
        or source:match("^%d+[uUlL]*", i)
      )
    local op = not space
      and not number
      and (
        source:match("^<<", i)
        or source:match("^>>", i)
        or source:match("^[<>=!]=", i)
        or source:match("^[<>|&^+%-*/%%~()]", i)
      )
    if space then
      i = i + #space
    elseif number then
      local v = M.parse(number)
      if not v then
        return nil
      end
      out[#out + 1] = { value = v }
      i = i + #number
    elseif op then
      out[#out + 1] = { op = op }
      i = i + #op
    else
      return nil
    end
  end
  return out
end

local binary_op, unary

local function primary(state)
  local token = state.tokens[state.at]
  if not token then
    return nil
  end
  if token.value then
    state.at = state.at + 1
    return token.value
  end
  if token.op == "(" then
    state.at = state.at + 1
    local v = binary_op(state, 1)
    local close = state.tokens[state.at]
    if not v or not close or close.op ~= ")" then
      return nil
    end
    state.at = state.at + 1
    return v
  end
end

function unary(state)
  local token = state.tokens[state.at]
  if token and (token.op == "~" or token.op == "-" or token.op == "+") then
    state.at = state.at + 1
    local v = unary(state)
    if not v then
      return nil
    end
    if token.op == "-" then
      state.negative = true
      return 0ULL - v
    end
    return token.op == "~" and bit.bnot(v) or v
  end
  return primary(state)
end

local function truth(yes)
  return yes and 1ULL or 0ULL
end

function binary_op(state, loosest)
  local left = unary(state)
  while left do
    local token = state.tokens[state.at]
    local binds = token and token.op and PRECEDENCE[token.op]
    if not binds or binds < loosest then
      break
    end
    state.at = state.at + 1
    local right = binary_op(state, binds + 1)
    if not right then
      return nil
    end
    local op = token.op
    if op == "|" then
      left = bit.bor(left, right)
    elseif op == "^" then
      left = bit.bxor(left, right)
    elseif op == "&" then
      left = bit.band(left, right)
    elseif PRECEDENCE[op] <= 5 then
      state.compared = true
      left = truth(
        op == "==" and left == right
          or op == "!=" and left ~= right
          or op == "<" and left < right
          or op == "<=" and left <= right
          or op == ">" and left > right
          or op == ">=" and left >= right
      )
    elseif op == "<<" or op == ">>" then
      if right > 63ULL then
        return nil
      end
      left = (op == "<<" and bit.lshift or bit.rshift)(left, tonumber(right))
    elseif op == "+" then
      left = left + right
    elseif op == "-" then
      state.negative = state.negative or right > left
      left = left - right
    elseif op == "*" then
      left = left * right
    else
      if right == 0ULL then
        return nil
      end
      left = op == "/" and left / right or left % right
    end
  end
  return left
end

-- An expression of literals and C's integer operators, worked out as lines,
-- or nil when it is none: a name in it, a division by zero, a shift past 63.
-- A comparison answers true or false; a result below zero is shown signed.
function M.calculate(source)
  local list = tokens(source or "")
  if not list or #list == 0 then
    return nil
  end
  local state = { tokens = list, at = 1 }
  local v = binary_op(state, 1)
  if not v or state.at <= #list then
    return nil
  end
  if state.compared and (v == 0ULL or v == 1ULL) then
    return { vim.trim(source), v == 1ULL and "true" or "false" }
  end
  -- Below zero, the binary of 64 bits and the bits set say nothing to read.
  if state.negative and top_bit(v) == 63 then
    return { vim.trim(source), "dec  -" .. group(decimal(0ULL - v), 3, ","), "hex  " .. hex(v) .. "  (64-bit)" }
  end
  local out = { vim.trim(source) }
  vim.list_extend(out, rows(v))
  return out
end

local function show(lines)
  vim.lsp.util.open_floating_preview(lines, "", { border = "rounded", focus_id = "taka_radix" })
end

-- An expression typed, as :Radix 1 << 6 | 2, in every base.
function M.command(text)
  local lines = M.calculate(text)
  if not lines then
    return vim.notify("Not an expression of numbers: " .. text, vim.log.levels.WARN)
  end
  show(lines)
end

-- The literal under the cursor, or the expression selected, in every base.
function M.show()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local text = table.concat(vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode }), " ")
    vim.cmd("normal! \27")
    local lines = M.calculate(text)
    if not lines then
      return vim.notify("Not an expression of numbers: " .. vim.trim(text), vim.log.levels.WARN)
    end
    return show(lines)
  end
  local text = M.literal_at(vim.api.nvim_get_current_line(), vim.fn.col("."))
  local lines = text and M.describe(text)
  if not lines then
    return vim.notify("No number under the cursor", vim.log.levels.WARN)
  end
  show(lines)
end

return M

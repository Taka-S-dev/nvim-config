-- Text read as bytes from a source that may be in Shift-JIS, the way the
-- editor reads such a file ('fileencodings', lua/config/options.lua): UTF-8
-- when it is valid UTF-8, else cp932, else left as it is. rg, global and svn
-- hand over the bytes of the file, which drawn as they are come out garbled.
-- vim.iconv does not tell a failure: it writes `?` for what it cannot
-- convert, so the bytes are checked here first.
local M = {}

-- Whether `text` is valid UTF-8.
function M.is_utf8(text)
  if not text:find("[\128-\255]") then
    return true
  end
  local at, size = 1, #text
  while at <= size do
    local byte = text:byte(at)
    local length = byte < 0x80 and 1
      or (byte >= 0xC2 and byte <= 0xDF) and 2
      or (byte >= 0xE0 and byte <= 0xEF) and 3
      or (byte >= 0xF0 and byte <= 0xF4) and 4
    if not length or at + length - 1 > size then
      return false
    end
    for following = at + 1, at + length - 1 do
      local trail = text:byte(following)
      if trail < 0x80 or trail > 0xBF then
        return false
      end
    end
    at = at + length
  end
  return true
end

-- Whether the bytes of `text` can be cp932: each a character of one byte, or a
-- lead byte with the trail byte it needs.
local function is_cp932(text)
  local at, size = 1, #text
  while at <= size do
    local byte = text:byte(at)
    if (byte >= 0x81 and byte <= 0x9F) or (byte >= 0xE0 and byte <= 0xFC) then
      local trail = text:byte(at + 1)
      if not trail or trail < 0x40 or trail == 0x7F or trail > 0xFC then
        return false
      end
      at = at + 2
    elseif byte == 0x80 or byte == 0xA0 or byte > 0xFC then
      return false
    else
      at = at + 1
    end
  end
  return true
end

-- The bytes of a cp932 text in UTF-8, or nil when they are not cp932.
local function from_cp932(text)
  return is_cp932(text) and vim.iconv(text, "cp932", "utf-8") or nil
end

-- One line as the editor would show it, and whether it had to be converted.
function M.text(line)
  if M.is_utf8(line) then
    return line, false
  end
  local converted = from_cp932(line)
  return converted or line, converted ~= nil
end

-- The lines of a whole file as the editor would show them, and whether they
-- had to be converted: one encoding for the file, as it has when opened.
function M.lines(lines)
  local whole = table.concat(lines, "\n")
  if M.is_utf8(whole) then
    return lines, false
  end
  local converted = from_cp932(whole)
  if not converted then
    return lines, false
  end
  return vim.split(converted, "\n", { plain = true }), true
end

-- A byte offset into the bytes of `line`, as an offset into the text shown;
-- the same offset when the bytes before it are not cp932, as when it falls
-- inside a character.
function M.column(line, offset)
  local converted = from_cp932(line:sub(1, offset))
  return converted and #converted or offset
end

-- `character` of UTF-8 or its bytes in cp932, for a pattern of rg. The bytes
-- keep to their own case: a trail byte can be a letter. A character cp932
-- does not have is left as it is, iconv giving a `?` for it.
local function either(character)
  local bytes = vim.iconv(character, "utf-8", "cp932")
  if not bytes or bytes:find("?", 1, true) then
    return character
  end
  local escaped = bytes:gsub(".", function(byte)
    return ("\\x%02x"):format(byte:byte())
  end)
  return ("(?:%s|(?-iu:%s))"):format(character, escaped)
end

-- `.` matches a whole character only in valid UTF-8: left alone, `foo.*bar`
-- stopped at the first Japanese letter of a line in cp932.
local ANY = [[(?:.|(?-u:[\x80-\xff]))]]

-- What a regular expression needs escaped when the text typed is searched for
-- as it stands.
local META = "[\\.+*?()|%[%]{}^$]"

-- A search for rg that finds `text` in UTF-8 and in cp932 alike, and whether
-- it differs from `text`. `fixed` is text to be found as it stands, for which
-- the result is a regular expression. Inside a [class] nothing is changed: a
-- class holds single characters and a character of cp932 is two bytes.
function M.pattern(text, fixed)
  if fixed and not text:find("[\128-\255]") then
    return text, false
  end
  local out, escaped, in_class = {}, false, false
  for character in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local piece = character
    if fixed then
      piece = #character > 1 and either(character) or character:gsub(META, "\\%0")
    elseif escaped then
      escaped = false
    elseif character == "\\" then
      escaped = true
    elseif in_class then
      in_class = character ~= "]"
    elseif character == "[" then
      in_class = true
    elseif character == "." then
      piece = ANY
    elseif #character > 1 then
      piece = either(character)
    end
    out[#out + 1] = piece
  end
  local pattern = table.concat(out)
  return pattern, pattern ~= text
end

return M

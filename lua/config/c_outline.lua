-- What a C file holds, read from its syntax tree: its functions with the
-- calls in each, its macros and its prototypes. Used by the call tree
-- (lua/config/call_tree/gtags.lua) and, for the function a line is in, by
-- lua/config/enclosing.lua, where the grammar alone cannot tell: a function
-- an #ifdef hides from the grammar is found by its layout here.
local M = {}

-- The functions, calls, macros and prototypes of each file read, as of its
-- size and time.
local outlines = {}

local QUERY = [[
(function_definition) @function
(call_expression function: (identifier) @call)
(preproc_def name: (identifier) @macro)
(preproc_function_def name: (identifier) @macro)
(declaration declarator: (function_declarator declarator: (identifier) @prototype))
(declaration
  declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @prototype)))
]]
local query

-- The last line a node takes; one that ends at the start of a line, as a
-- #define does with its newline, ends on the line before.
local function last_line(node)
  local _, _, row, col = node:range()
  return col == 0 and row or row + 1
end

-- Words that are never the name of a function, though they can look like one:
-- after an #ifdef the grammar could not follow, `} else if (x) {` passed with
-- it for the definition of a function named if, over 60 lines of the function
-- it was in, and a line starting with one of them looks like a header to the
-- layout below.
local NOT_NAMES = { ["if"] = true, ["for"] = true, ["while"] = true, ["switch"] = true, ["return"] = true }

-- The name a function definition declares: inside the declarator, past the
-- pointers and parentheses of `int *(f)(void)`, the one a parameter list
-- follows.
local function function_name(node, source)
  local declarator = node:field("declarator")[1]
  while declarator and declarator:type() ~= "function_declarator" do
    declarator = declarator:field("declarator")[1] or declarator:named_child(0)
  end
  local name = declarator and declarator:field("declarator")[1]
  while name and name:type() == "parenthesized_declarator" do
    name = name:named_child(0)
  end
  if name and name:type() == "identifier" then
    local text = vim.treesitter.get_node_text(name, source)
    return not NOT_NAMES[text] and text or nil
  end
end

-- Function bodies found by their layout, for the parts of a file the grammar
-- could not read: an #ifdef around half of a function leaves the rest of the
-- file one error to it, with no function in it. A body opens with a brace in
-- the first column, or at the end of a header line that starts there, and
-- ends at the next closing brace in the first column; its header is the line
-- above, at most a few, that starts in the first column with a name and a
-- parenthesis after it. It is how C is laid out almost everywhere, and what
-- Vim's own [[ goes by.
local function bodies_by_layout(source)
  local lines = vim.split(source, "\n", { plain = true })
  local bodies, at = {}, 1
  while at <= #lines do
    local header
    if lines[at]:match("^{") then
      for up = at - 1, math.max(1, at - 8), -1 do
        local text = lines[up]
        if text:match("^[}#]") or text:match(";%s*$") then
          break
        end
        if text:match("^[%a_]") and text:find("(", 1, true) then
          header = up
          break
        end
      end
    elseif lines[at]:match("^[%a_]") and lines[at]:find("(", 1, true) and lines[at]:match("{%s*$") then
      header = at
    end
    local name = header and lines[header]:match("([%a_][%w_]*)%s*%(")
    if name and not NOT_NAMES[name] then
      local last = at
      while last < #lines and not lines[last]:match("^}") do
        last = last + 1
      end
      table.insert(bodies, { kind = "function", name = name, first = header, last = last, calls = {} })
      at = last
    end
    at = at + 1
  end
  return bodies
end

function M.read(file)
  local stat = vim.uv.fs_stat(file)
  if not stat then
    return nil
  end
  local key = ("%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
  if outlines[file] and outlines[file].key == key then
    return outlines[file]
  end
  local result = { key = key, functions = {}, macros = {}, prototypes = {} }
  outlines[file] = result
  local handle = io.open(file, "rb")
  if not handle then
    return result
  end
  local source = handle:read("*a")
  handle:close()
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "c")
  if not ok then
    return result
  end
  query = query or vim.treesitter.query.parse("c", QUERY)
  local calls = {}
  local root = parser:parse()[1]:root()
  for id, node in query:iter_captures(root, source) do
    local capture = query.captures[id]
    local row = node:start() + 1
    local text = capture ~= "function" and vim.treesitter.get_node_text(node, source)
    if capture == "function" then
      local name = function_name(node, source)
      if name then
        local fn = { kind = "function", name = name, first = row, last = last_line(node), calls = {} }
        table.insert(result.functions, fn)
      end
    elseif capture == "call" then
      calls[#calls + 1] = { name = text, line = row }
    elseif capture == "macro" then
      table.insert(result.macros, { kind = "macro", name = text, first = row, last = last_line(node:parent()) })
    else
      result.prototypes[row .. ":" .. text] = true
    end
  end
  -- A body found by layout fills a part the grammar found no function in; where
  -- it did find one, that one stands.
  if root:has_error() then
    for _, body in ipairs(bodies_by_layout(source)) do
      local taken = false
      for _, fn in ipairs(result.functions) do
        taken = taken or (fn.first <= body.last and body.first <= fn.last)
      end
      if not taken then
        table.insert(result.functions, body)
      end
    end
    table.sort(result.functions, function(a, b)
      return a.first < b.first
    end)
  end
  -- Captures come in the order of the file, a function before the calls in it.
  local at = 1
  for _, call in ipairs(calls) do
    while result.functions[at] and result.functions[at].last < call.line do
      at = at + 1
    end
    local fn = result.functions[at]
    if fn and fn.first <= call.line then
      table.insert(fn.calls, call)
    end
  end
  return result
end

-- The function, or the body of the macro, a line of a file stands in.
function M.enclosing(file_outline, line)
  for _, list in ipairs({ "functions", "macros" }) do
    for _, body in ipairs(file_outline and file_outline[list] or {}) do
      if body.first <= line and line <= body.last then
        return body
      end
    end
  end
end

return M

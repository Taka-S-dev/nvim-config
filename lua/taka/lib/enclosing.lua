-- The name of the function a place in a buffer is in, for any language
-- treesitter has a parser for: the nearest node around the place whose type
-- says function or method, and in its declarator or name the first name.
-- Used by the pins (lua/taka/pins/) and the jump stack
-- (lua/taka/jump_stack.lua).
local M = {}

-- What treesitter hands back as a name when a declaration is wrapped in macros
-- and calling conventions, as in ms/applink.c: not a function name.
local not_a_name = {}
for word in ("void int char short long float double signed unsigned static const struct union enum"):gmatch("%S+") do
  not_a_name[word] = true
end
M.not_a_name = not_a_name

local function names_a_function(kind)
  -- A call is no function of its own, though Lua's is a function_call and
  -- its name is the function called.
  return (kind:find("function") or kind:find("method")) and not kind:find("call") and not kind:find("parameter")
end

-- The function line `row` (1-based) of `buf` is in, or "" where it is in none
-- or the buffer has no parser. The place looked at is the first character of
-- the line that is not a blank, inside whatever the line holds.
function M.at(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not line then
    return ""
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return ""
  end
  parser:parse({ row - 1, row })
  local col = (line:find("%S") or 1) - 1
  local found_node, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row - 1, col } })
  while found_node and node do
    if names_a_function(node:type()) then
      local found
      local function search(n, depth)
        if found or depth > 6 then
          return
        end
        if n:type() == "identifier" or n:type() == "field_identifier" then
          found = vim.treesitter.get_node_text(n, buf)
          return
        end
        for child in n:iter_children() do
          if child:type() ~= "compound_statement" and child:type() ~= "block" and child:type() ~= "parameter_list" then
            search(child, depth + 1)
          end
        end
      end
      local declarator = node:field("declarator")[1] or node:field("name")[1]
      if declarator then
        search(declarator, 0)
      end
      if found and not not_a_name[found] then
        return found
      end
    end
    node = node:parent()
  end
  -- In C an #ifdef can leave the rest of a file one error to the grammar,
  -- with no function in it; the C reader finds the function by its layout.
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].filetype == "c" and name ~= "" then
    return require("taka.lib.c_outline").function_at(name, row) or ""
  end
  return ""
end

-- The kinds of node a definition is: a function, a type, a declaration, a
-- macro. A parameter or a field is part of one, not one of its own.
local function is_definition(kind)
  if kind == "parameter_declaration" or kind == "field_declaration" then
    return false
  end
  return kind:find("definition$") ~= nil
    or kind:find("declaration$") ~= nil
    or kind == "struct_specifier"
    or kind == "union_specifier"
    or kind == "enum_specifier"
    or kind == "preproc_def"
    or kind == "preproc_function_def"
end

-- The first line (1-based) of the definition line `row` of `buf` is in, with
-- the comments right above it: the comment that says what a function does,
-- and the members of a struct, which come before the line its name is on in
-- `typedef struct { ... } name;`. The last line of the definition too. nil
-- where the buffer has no parser or the line is in no definition.
function M.head(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not line then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  parser:parse({ math.max(row - 400, 0), row + 1 })
  local col = (line:find("%S") or 1) - 1
  local found_node, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row - 1, col } })
  if not found_node then
    return nil
  end
  while node and not is_definition(node:type()) do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local top = node:start()
  local last = select(1, node:end_())
  local above = node:prev_sibling()
  while above and above:type() == "comment" and select(1, above:end_()) >= top - 1 do
    top = above:start()
    above = above:prev_sibling()
  end
  return top + 1, last + 1
end

return M

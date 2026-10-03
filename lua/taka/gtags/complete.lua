-- Completion for C from GTAGS: the names of the whole project as a word is
-- typed, and after `->` or `.` the members of what stands before it.
--
-- Names come from `global -c` (definitions) and `global -cs` (other symbols,
-- such as enum values), from two letters on; a list that comes back whole is
-- narrowed by the menu as more is typed, without asking again.
--
-- A member list needs the type of what stands before the operator, which GTAGS
-- does not record. The expression `a->b.c[i]` is read off the line, the type of
-- its first name is taken from the declarations around the cursor (the
-- function's parameters, the blocks the cursor is in, the file), and for a
-- global of another file from GTAGS, its definitions and then its other
-- symbols, where GTAGS keeps a global variable. Each name after it is looked up
-- among the members of the type before, the struct body read with treesitter in
-- the file `global -d` names for it, typedefs followed up to ten times. A type
-- that cannot be told offers nothing rather than a guess: a cast, a call,
-- `(*p).`, a macro. The members are ordered by how often the file uses them, as
-- a struct of a hundred members put rarely used ones first in name order. After
-- `.` on a pointer, the choice turns the `.` into `->`.
local M = {}

local global = require("taka.lib.gtags_global")

-- The output of `global args` in `root`, from inside a coroutine.
local function ask(root, args)
  local co = coroutine.running()
  global.ask(root, args, function(output)
    vim.schedule(function()
      coroutine.resume(co, output or "")
    end)
  end)
  return coroutine.yield()
end

-- `global -x` lines: { name, line, path }.
local function places(output)
  local found = {}
  for line in vim.gsplit(output, "\n", { trimempty = true }) do
    local name, lnum, path = line:gsub("\r$", ""):match("^(%S+)%s+(%d+)%s+(%S+)")
    if name then
      found[#found + 1] = { name = name, line = tonumber(lnum), path = path }
    end
  end
  return found
end

-- A source file parsed with treesitter, kept until the file changes.
local files = {}

local function parsed(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local kept = files[path]
  if kept and kept.mtime == stat.mtime.sec then
    return kept
  end
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "c")
  if not ok then
    return nil
  end
  kept = { mtime = stat.mtime.sec, root = parser:parse()[1]:root(), text = text }
  files[path] = kept
  return kept
end

-- The innermost node of one of `types` whose lines take in `line` (0-based).
local function around(root, line, types)
  local found
  local function visit(node)
    local first, _, last = node:range()
    if line < first or line > last then
      return
    end
    if types[node:type()] then
      found = node
    end
    for child in node:iter_children() do
      visit(child)
    end
  end
  visit(root)
  return found
end

-- What a declarator declares: its name and whether it is a pointer. The name
-- is under pointers, arrays, initialisers and a function pointer's brackets.
local function declared(node, src)
  local pointer = false
  while node do
    local t = node:type()
    if t == "identifier" or t == "field_identifier" or t == "type_identifier" then
      return vim.treesitter.get_node_text(node, src), pointer
    end
    if t == "pointer_declarator" then
      pointer = true
    end
    if t == "parenthesized_declarator" then
      node = node:named_child(0)
    else
      node = node:field("declarator")[1]
    end
  end
end

-- A type as it is written, reduced to what can hold members: a struct or
-- union by its tag or by its body, or a typedef's name. Anything else is nil.
local function type_of(node, src)
  if not node then
    return nil
  end
  local t = node:type()
  if t == "struct_specifier" or t == "union_specifier" then
    local body = node:field("body")[1]
    if body then
      return { body = body, src = src }
    end
    local name = node:field("name")[1]
    return name and { tag = vim.treesitter.get_node_text(name, src) }
  end
  if t == "type_identifier" then
    return { name = vim.treesitter.get_node_text(node, src) }
  end
end

-- Each name a declaration declares, with its type: { name, type, pointer,
-- text }, text the type as written, for the menu.
local function declarations(node, src)
  local out = {}
  local written = node:field("type")[1]
  local type = type_of(written, src)
  local text = not written and "" or type and type.body and "struct {...}" or vim.treesitter.get_node_text(written, src)
  for _, declarator in ipairs(node:field("declarator")) do
    local name, pointer = declared(declarator, src)
    if name then
      out[#out + 1] = { name = name, type = type, pointer = pointer, text = text .. (pointer and " *" or "") }
    end
  end
  return out
end

-- The members of a struct body; those of a struct or union inside it with no
-- name of its own belong to it, as C lets them be reached directly.
local function members_of_body(body, src)
  local out = {}
  for child in body:iter_children() do
    if child:type() == "field_declaration" then
      local found = declarations(child, src)
      if #found == 0 then
        local inner = child:field("type")[1]
        local anon = type_of(inner, src)
        if anon and anon.body then
          vim.list_extend(out, members_of_body(anon.body, src))
        end
      end
      vim.list_extend(out, found)
    end
  end
  return out
end

local STRUCT = { struct_specifier = true, union_specifier = true }
local TYPEDEF = { type_definition = true }

-- The members of each struct or typedef name, per project until its GTAGS
-- changes: a struct is looked up once however often it is reached.
local known = {} ---@type table<string, { mtime: integer, types: table<string, table|false> }>

local function known_of(root)
  local stat = vim.uv.fs_stat(vim.fs.joinpath(root, "GTAGS"))
  local mtime = stat and stat.mtime.sec or 0
  if not known[root] or known[root].mtime ~= mtime then
    known[root] = { mtime = mtime, types = {} }
  end
  return known[root].types
end

-- The members of a type, or nil when they cannot be told. Run in a coroutine.
local members, look_up
members = function(root, type, hops)
  if not type or (hops or 0) > 10 then
    return nil
  end
  if type.body then
    return members_of_body(type.body, type.src)
  end
  local key = (type.tag and "struct " or "") .. (type.tag or type.name)
  local types = known_of(root)
  if types[key] == nil then
    types[key] = look_up(root, type, hops) or false
  end
  return types[key] or nil
end

look_up = function(root, type, hops)
  local name = type.tag or type.name
  for _, at in ipairs(places(ask(root, { "-d", "-x", name }))) do
    local file = parsed(vim.fs.joinpath(root, at.path))
    if file then
      if type.tag or not type.name then
        local node = around(file.root, at.line - 1, STRUCT)
        local found = node and type_of(node, file.text)
        if found and found.body then
          return members_of_body(found.body, file.text)
        end
      end
      if type.name then
        local node = around(file.root, at.line - 1, TYPEDEF)
        if node then
          for _, d in ipairs(declarations(node, file.text)) do
            if d.name == name then
              return members(root, d.type, (hops or 0) + 1)
            end
          end
        end
        -- A struct named without `struct`, as C++ allows.
        local spec = around(file.root, at.line - 1, STRUCT)
        local found = spec and type_of(spec, file.text)
        if found and found.body then
          return members_of_body(found.body, file.text)
        end
      end
    end
  end
end

local SCOPES = { compound_statement = true, function_definition = true, translation_unit = true }

-- The declaration of `name` nearest the cursor in the buffer: the blocks the
-- cursor is in from the inside out, the function's parameters, the file.
local function local_declaration(buf, row, col, name)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  local node = tree:root():named_descendant_for_range(row, col, row, col)
  while node do
    local found
    if SCOPES[node:type()] then
      for child in node:iter_children() do
        local first = child:range()
        if child:type() == "declaration" and first <= row then
          for _, d in ipairs(declarations(child, buf)) do
            if d.name == name then
              found = d
            end
          end
        end
      end
      if not found and node:type() == "function_definition" then
        local fn = node:field("declarator")[1]
        while fn and fn:type() ~= "function_declarator" do
          fn = fn:field("declarator")[1]
        end
        local params = fn and fn:field("parameters")[1]
        for param in params and params:iter_children() or function() end do
          if param:type() == "parameter_declaration" then
            for _, d in ipairs(declarations(param, buf)) do
              if d.name == name then
                found = d
              end
            end
          end
        end
      end
    end
    if found then
      return found
    end
    node = node:parent()
  end
end

-- The declaration of a global `name` in another file. GTAGS records a global
-- variable among the other symbols (`-s`), not the definitions, so its places
-- are read too, the first few, for one that declares it.
local function global_declaration(root, name)
  for _, kind in ipairs({ "-d", "-s" }) do
    for index, at in ipairs(places(ask(root, { kind, "-x", name }))) do
      if index > 20 then
        break
      end
      local file = parsed(vim.fs.joinpath(root, at.path))
      local node = file and around(file.root, at.line - 1, { declaration = true })
      if file and node then
        for _, d in ipairs(declarations(node, file.text)) do
          if d.name == name then
            return d
          end
        end
      end
    end
  end
end

-- The member access being typed at the end of `before`: the names of the
-- expression, the operator and the part of the member typed so far. nil when
-- the text does not end in one, or the expression is not a plain chain.
function M.chain(before)
  local partial = before:match("[%a_][%w_]*$") or ""
  local rest = before:sub(1, #before - #partial)
  local op = rest:match("%->%s*$") and "->" or rest:match("%.%s*$") and "." or nil
  if not op then
    return nil
  end
  rest = rest:gsub("%s*" .. vim.pesc(op) .. "%s*$", "")
  local names = {}
  while true do
    rest = rest:gsub("%s+$", "")
    while rest:sub(-1) == "]" do
      local cut = rest:gsub("%b[]$", "")
      if cut == rest then
        return nil
      end
      rest = cut:gsub("%s+$", "")
    end
    local name = rest:match("[%a_][%w_]*$")
    if not name then
      return nil
    end
    table.insert(names, 1, name)
    rest = rest:sub(1, #rest - #name)
    local trimmed = rest:gsub("%s+$", "")
    if trimmed:match("%->$") then
      rest = trimmed:sub(1, -3)
    elseif trimmed:match("%.$") then
      rest = trimmed:sub(1, -2)
    else
      -- A cast or a call before the first name, or `(*p)`: not a plain chain.
      if trimmed:match("[%)%]]$") then
        return nil
      end
      break
    end
  end
  return { names = names, op = op, partial = partial }
end

-- How often each name is used in the buffer.
local function frequency(buf)
  local count = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for word in line:gmatch("[%a_][%w_]*") do
      count[word] = (count[word] or 0) + 1
    end
  end
  return count
end

-- The members to offer for `chain` at the cursor: { name, type text, pointer
-- of the base }, nil when the type is not known. Run in a coroutine.
local function member_candidates(root, buf, row, col, chain)
  local head = local_declaration(buf, row, col, chain.names[1]) or global_declaration(root, chain.names[1])
  if not head then
    return nil
  end
  local type, pointer = head.type, head.pointer
  for i = 2, #chain.names do
    local list = members(root, type)
    local next
    for _, m in ipairs(list or {}) do
      if m.name == chain.names[i] then
        next = m
      end
    end
    if not next then
      return nil
    end
    type, pointer = next.type, next.pointer
  end
  return members(root, type), pointer
end

-- The candidates at the cursor of `buf`, handed to `done(result)` where result
-- is { kind = "member" | "name", items = { { label, detail } }, partial,
-- complete, dot_on_pointer } or nil.
function M.candidates(buf, row, col, done)
  local name = vim.api.nvim_buf_get_name(buf)
  local root = name ~= "" and vim.fs.root(name, "GTAGS") or nil
  if not root or vim.fn.executable("global") == 0 then
    return done(nil)
  end
  local before = (vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""):sub(1, col)
  local chain = M.chain(before)
  coroutine.wrap(function()
    if chain then
      local list, pointer = member_candidates(root, buf, row, col, chain)
      if not list then
        return done(nil)
      end
      local count, items, seen = frequency(buf), {}, {}
      for _, m in ipairs(list) do
        if not seen[m.name] then
          seen[m.name] = true
          items[#items + 1] = { label = m.name, detail = m.text, uses = count[m.name] or 0 }
        end
      end
      table.sort(items, function(a, b)
        if a.uses ~= b.uses then
          return a.uses > b.uses
        end
        return a.label < b.label
      end)
      return done({
        kind = "member",
        items = items,
        partial = chain.partial,
        complete = true,
        dot_on_pointer = chain.op == "." and pointer,
      })
    end
    local word = before:match("[%a_][%w_]*$") or ""
    if #word < 2 or before:sub(1, #before - #word):match("[%w_]$") then
      return done(nil)
    end
    local items, seen = {}, {}
    for _, args in ipairs({ { "-c", word }, { "-cs", word } }) do
      for found in vim.gsplit(ask(root, args), "\n", { trimempty = true }) do
        found = vim.trim(found)
        if found ~= "" and not seen[found] then
          seen[found] = true
          items[#items + 1] = { label = found }
        end
      end
    end
    done({ kind = "name", items = items, partial = word, complete = true })
  end)()
end

return M

-- Call trees from GTAGS, for lua/taka/call_tree/init.lua.
--
-- Callers come from the references global finds (global -r), each put under
-- the function it stands in, which the file's syntax tree tells. Callees come
-- from the calls in the function's own body, read the same way, with where
-- each is defined from global -d. gtags goes by name, and so does this: a call
-- through a function pointer is not seen, nor one made in the body of a macro,
-- and two static functions of one name in different files are taken for one.
local M = {}

local c_outline = require("taka.lib.c_outline")
local outline, enclosing = c_outline.read, c_outline.enclosing

-- `global --result=ctags` prints `name<Tab>path<Tab>line`: a path with spaces
-- in it stays whole, and the name tells the answers to several names apart.
local function hits_of(output)
  local hits = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local name, file, lnum = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
    if name then
      hits[#hits + 1] = { name = name, file = vim.fs.normalize(file), lnum = tonumber(lnum) }
    end
  end
  return hits
end

-- Through ask, not run: a function no one calls rightly finds nothing.
local function ask(root, args, done, names)
  local global = require("taka.lib.gtags_global")
  local full = { "--result=ctags", "-a" }
  vim.list_extend(full, args)
  local function answer(output)
    done(hits_of(output))
  end
  if names then
    global.ask_names(root, full, names, answer)
  else
    global.ask(root, full, answer)
  end
end

-- Files read a few at a time, in turns of 15 ms, so that the editor keeps up
-- while the callers of a function used in hundreds of files are sorted out.
local function each_file(files, fn, done, progress)
  local index = 0
  local function step()
    local stop = vim.uv.hrtime() + 15e6
    while index < #files and vim.uv.hrtime() < stop do
      index = index + 1
      fn(files[index])
    end
    if index < #files then
      progress(("%d/%d files"):format(index, #files))
      vim.schedule(step)
    else
      done()
    end
  end
  step()
end

-- The function or macro named `name` in `list` that line `lnum` of GTAGS
-- points at: the one the line stands in, else the nearest of that name. GTAGS
-- is not brought up to date by an edit, so after lines are added above a
-- function its line is no longer in it; looked for by its line alone, the
-- function was not found, and its callees came out empty.
-- The second value is true when the line stands in it.
local function named(list, name, lnum)
  local nearest, distance
  for _, body in ipairs(list) do
    if body.name == name then
      if body.first <= lnum and lnum <= body.last then
        return body, true
      end
      local away = math.abs((body.line or body.first) - lnum)
      if not distance or away < distance then
        nearest, distance = body, away
      end
    end
  end
  return nearest, false
end

-- What a definition found by global is, and the line it is on now: a function
-- the file defines, a macro, or something else, such as a function declared by
-- a macro, left on the line global gives. The one the line stands in comes
-- first, a macro before a function, then the nearer of the two.
local function kind_at(file, lnum, name)
  local file_outline = outline(file)
  if not file_outline then
    return "other", lnum
  end
  local macro, in_macro = named(file_outline.macros, name, lnum)
  local fn, in_fn = named(file_outline.functions, name, lnum)
  if in_macro then
    return "macro", lnum
  end
  -- gtags gives the line of the name, which is not the first line of the
  -- function where the type before it has a line of its own.
  if in_fn then
    return "function", lnum
  end
  local function away(body)
    return body and math.abs((body.line or body.first) - lnum) or math.huge
  end
  if macro and away(macro) <= away(fn) then
    return "macro", macro.first
  end
  if fn then
    return "function", fn.line or fn.first
  end
  return "other", lnum
end

-- Where each of `nodes` is defined, filled in: in the file of the function
-- that calls it if it is defined there, since a static function of that name
-- elsewhere is another one, or else where global first finds it.
local function define(root, nodes, near, done, progress)
  local names, by_name = {}, {}
  for _, node in ipairs(nodes) do
    if not by_name[node.name] then
      by_name[node.name] = {}
      names[#names + 1] = node.name
    end
    table.insert(by_name[node.name], node)
  end
  if #names == 0 then
    return done()
  end
  ask(root, { "-d" }, function(hits)
    local found = {}
    for _, hit in ipairs(hits) do
      found[hit.name] = found[hit.name] or {}
      table.insert(found[hit.name], hit)
    end
    local files, seen = {}, {}
    for name, defs in pairs(found) do
      local pick = defs[1]
      for _, def in ipairs(defs) do
        if def.file == near then
          pick = def
        end
      end
      for _, node in ipairs(by_name[name] or {}) do
        node.file, node.lnum, node.others = pick.file, pick.lnum, #defs - 1
      end
      if not seen[pick.file] then
        seen[pick.file] = true
        files[#files + 1] = pick.file
      end
    end
    each_file(files, outline, function()
      for _, node in ipairs(nodes) do
        if node.file then
          node.kind, node.lnum = kind_at(node.file, node.lnum, node.name)
        else
          node.kind = "unknown"
        end
      end
      done()
    end, progress)
  end, names)
end

-- The functions that call `node`, each once, with the places it calls from.
-- A call in the body of a macro is listed under the macro, which opens to the
-- functions that use it; a reference outside both, as in a table of function
-- pointers, under its file.
local function callers(root, node, done, progress)
  ask(root, { "-r", node.name }, function(hits)
    local by_file, files = {}, {}
    for _, hit in ipairs(hits) do
      if not by_file[hit.file] then
        by_file[hit.file] = {}
        files[#files + 1] = hit.file
      end
      table.insert(by_file[hit.file], hit)
    end
    local children, groups = {}, {}
    each_file(files, function(file)
      local file_outline = outline(file)
      for _, hit in ipairs(by_file[file]) do
        -- A prototype names the function without calling it.
        local declared = file_outline and file_outline.prototypes[hit.lnum .. ":" .. node.name]
        local fn = not declared and enclosing(file_outline, hit.lnum)
        local key = file .. "#" .. (fn and fn.first or 0)
        if declared then
          key = nil
        elseif not groups[key] then
          groups[key] = {
            name = fn and fn.name or vim.fs.basename(file),
            kind = fn and fn.kind or "file",
            file = file,
            lnum = fn and fn.first or hit.lnum,
            sites = {},
          }
          children[#children + 1] = groups[key]
        end
        if key then
          table.insert(groups[key].sites, { file = file, lnum = hit.lnum })
        end
      end
    end, function()
      done(children)
    end, progress)
  end)
end

-- The functions `node` calls, each once, in the order of their first call.
local function callees(root, node, done, progress)
  local file_outline = node.file and outline(node.file)
  local fn = file_outline and named(file_outline.functions, node.name, node.lnum)
  if not fn then
    return done({})
  end
  local children, by_name = {}, {}
  for _, call in ipairs(fn.calls) do
    if not by_name[call.name] then
      by_name[call.name] = { name = call.name, kind = "unknown", sites = {} }
      children[#children + 1] = by_name[call.name]
    end
    -- One place a line, as global gives the callers: `f(1) + f(2)` is one.
    local sites = by_name[call.name].sites
    if not sites[#sites] or sites[#sites].lnum ~= call.line then
      table.insert(sites, { file = node.file, lnum = call.line })
    end
  end
  define(root, children, node.file, function()
    done(children)
  end, progress)
end

-- A session for the buffer, or nil and why not: there is no GTAGS above it.
function M.attach(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local root = require("taka.lib.gtags_global").root(file)
  if not root or vim.fn.executable("global") == 0 then
    return nil, "No GTAGS for this file. Build one with <leader>jb."
  end
  local session = { unknown = "not in GTAGS" }

  -- The function under the cursor if a function is what the word there names,
  -- else the function the cursor is in.
  function session.start(_, _, done)
    local here_file = vim.fs.normalize(file)
    local word = vim.fn.expand("<cword>")
    local around = enclosing(outline(here_file), vim.fn.line("."))
    local function fallback()
      if around then
        done({ name = around.name, kind = "function", file = here_file, lnum = around.first })
      else
        done(nil, "No function under or around the cursor")
      end
    end
    if not word:match("^[%a_][%w_]*$") then
      return fallback()
    end
    local probe = { name = word, kind = "unknown" }
    define(root, { probe }, here_file, function()
      if probe.kind == "function" then
        done(probe)
      else
        fallback()
      end
    end, function() end)
  end

  function session.children(_, node, direction, done, progress)
    local find = direction == "callers" and callers or callees
    find(root, node, done, progress)
  end

  -- Functions branch both ways. A macro branches to its callers, the
  -- functions that reach a call through it, but not to what it calls: its
  -- body is not read as code. A name global does not define, a library
  -- function or a pointer, has no body to read.
  function session.branches(_, node, direction)
    return node.kind == "function" or (node.kind == "macro" and direction == "callers")
  end

  return session
end

return M

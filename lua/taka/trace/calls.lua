-- Whether one C function calls another, for the depth the trace panel
-- (lua/taka/trace/panel.lua) gives a function a trace goes into: a call
-- written in the body of the caller, read from its syntax tree
-- (lua/taka/lib/c_outline.lua); a call through a macro the body uses, as
-- OPENSSL_malloc stands for CRYPTO_malloc; or a call from a function the
-- caller calls, one only, as PEM_read_bio_ex calls CRYPTO_malloc through
-- pem_malloc. That function is named, so a call through it is not taken for
-- one made directly; further than one, most functions reach most others,
-- and the nesting would say nothing. Macros, and the files of functions
-- defined in another file, are looked up in GTAGS in the background: what is
-- not known yet is not a call, and the panel is drawn again once it is.
local M = {}

local outline = require("taka.lib.c_outline")

-- What GTAGS says of a name of a project, by the GTAGS root and the name:
-- { calls = names a macro calls } for a macro, { file = path } for a
-- function defined in one file, {} for neither, or "asking".
local known = {}

-- The names called in the body of `func` of `file`, or nil where the file has
-- no such function.
local function called_by(file, func)
  local read = outline.read(vim.fs.normalize(file))
  for _, fn in ipairs(read and read.functions or {}) do
    if fn.name == func then
      local names = {}
      for _, call in ipairs(fn.calls) do
        names[call.name] = true
      end
      return names
    end
  end
end

-- The names a macro defined at `lnum` of `path` calls, its lines continued
-- with backslashes read as one.
local function names_in_define(path, lnum)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return {}
  end
  local text, at = "", lnum
  repeat
    local line = lines[at] or ""
    text = text .. " " .. line:gsub("\\%s*$", "")
    at = at + 1
  until not (lines[at - 1] or ""):match("\\%s*$") or at > lnum + 40
  -- The macro's own name and parameters are not a call of it.
  text = text:gsub("^%s*#%s*define%s+[%a_][%w_]*", "")
  local names = {}
  for name in text:gmatch("([%a_][%w_]*)%s*%(") do
    names[name] = true
  end
  return names
end

-- Asks GTAGS for the definitions of `names`: what each macro calls, and the
-- file of each function.
local function ask(root, names, done)
  for _, name in ipairs(names) do
    known[root .. "\0" .. name] = "asking"
  end
  require("taka.lib.gtags_global").ask_names(root, { "-x", "-d" }, names, function(output)
    local found = {}
    for line in (output or ""):gmatch("[^\r\n]+") do
      local name, lnum, path, text = line:match("^(%S+)%s+(%d+)%s+(%S+)%s?(.*)$")
      if name then
        local entry = found[name] or { files = {} }
        found[name] = entry
        local full = vim.fs.joinpath(root, path)
        if text:match("^%s*#%s*define%s+" .. vim.pesc(name) .. "%f[^%w_]") then
          entry.calls = entry.calls or {}
          for called in pairs(names_in_define(full, tonumber(lnum))) do
            entry.calls[called] = true
          end
        else
          entry.files[full:lower()] = full
        end
      end
    end
    for _, name in ipairs(names) do
      local entry = found[name]
      local result = {}
      if entry and entry.calls then
        result.calls = entry.calls
      elseif entry then
        -- A function defined in one file only: one of the same name in
        -- several files, a static one each, cannot be told apart here.
        local files = vim.tbl_values(entry.files)
        result.file = #files == 1 and files[1] or nil
      end
      known[root .. "\0" .. name] = result
    end
    done()
  end)
end

-- What is known of `names` under `root`, the names not asked yet asked
-- about: a table by name, and whether anything is still to come.
local function lookup(root, names, on_known)
  local out, unknown, waiting = {}, {}, false
  for name in pairs(names) do
    local entry = known[root .. "\0" .. name]
    if entry == nil then
      unknown[#unknown + 1] = name
    elseif entry == "asking" then
      waiting = true
    else
      out[name] = entry
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    ask(root, unknown, on_known)
    waiting = true
  end
  return out, waiting
end

-- Whether the body of `func` of `file` calls `callee` itself, or through a
-- macro it uses: true, false, or nil while a macro is being looked up.
local function reaches(file, func, callee, root, on_known)
  local names = called_by(file, func)
  if not names then
    return false
  end
  if names[callee] then
    return true
  end
  if not root then
    return false
  end
  local entries, waiting = lookup(root, names, on_known)
  for _, entry in pairs(entries) do
    if entry.calls and entry.calls[callee] then
      return true
    end
  end
  if waiting then
    return nil
  end
  return false
end

-- How `func` of `file` calls `callee`: "" for a call of its own, or through
-- a macro; the name of the function it calls that makes the call; false for
-- none seen; or nil while something is being looked up, `on_known` called
-- once it is.
function M.via(file, func, callee, on_known)
  local root = require("taka.lib.gtags_global").root(file)
  if root and vim.fn.executable("global") == 0 then
    root = nil
  end
  local direct = reaches(file, func, callee, root, on_known)
  if direct then
    return ""
  end
  local pending = direct == nil
  local names = called_by(file, func) or {}
  local here = outline.read(vim.fs.normalize(file))
  local local_functions = {}
  for _, fn in ipairs(here and here.functions or {}) do
    local_functions[fn.name] = true
  end
  local entries = {}
  if root then
    local waiting
    entries, waiting = lookup(root, names, on_known)
    pending = pending or waiting
  end
  local sorted = vim.tbl_keys(names)
  table.sort(sorted)
  for _, name in ipairs(sorted) do
    local helper_file = local_functions[name] and file or (entries[name] and entries[name].file)
    if name ~= func and name ~= callee and helper_file then
      local through = reaches(helper_file, name, callee, root, on_known)
      if through then
        return name
      end
      pending = pending or through == nil
    end
  end
  if pending then
    return nil
  end
  return false
end

-- For the checks: what is known of the names of projects forgotten.
function M.forget()
  known = {}
end

return M

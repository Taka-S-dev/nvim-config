-- Traces as stored: one file per investigation under Neovim's data directory,
-- written by whoever traced the code, a person or a tool, and read here. Nothing
-- here draws.
--
-- A trace is JSON Lines, one step a line, so that steps can be added to the end
-- of it while it is read:
--
--   {"title": "Why the handshake fails", "root": "C:/src/openssl"}
--   {"file": "ssl/statem/statem.c", "line": 120, "title": "Enters here", "note": "..."}
--   {"id": "w", "file": "ssl/d1_srtp.c", "line": 88, "title": "Writes len", "kind": "cause"}
--   {"parent": "w", "file": "ssl/d1_srtp.c", "line": 61, "title": "Where len comes from"}
--
-- A line without "line" is the header. A path that is not absolute is under
-- "root", or the cwd. A step is under the step its "parent" names, else at the
-- top, in the order written. "note" may run over several lines, as a string
-- with line breaks or a list of strings. "kind" is "cause", "suspect" or left
-- out. "text" is what the line says, the whole of it or a part, by which the
-- step is found again once the line has moved. A file that is one JSON object
-- with a "steps" list is read too.
--
-- The reader may change the title and the note of a step. Its line in the file
-- is written again with them and "edited": true, so that whoever wrote the
-- trace and goes on with it knows the words are the reader's.
local M = {}

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "traces")
end

-- The trace files, the newest first.
function M.files()
  local out = {}
  for name, kind in vim.fs.dir(M.dir()) do
    if kind == "file" and (name:match("%.jsonl$") or name:match("%.json$")) then
      local path = vim.fs.normalize(vim.fs.joinpath(M.dir(), name))
      local stat = vim.uv.fs_stat(path)
      out[#out + 1] = { path = path, mtime = stat and stat.mtime.sec + stat.mtime.nsec / 1e9 or 0 }
    end
  end
  table.sort(out, function(a, b)
    return a.mtime > b.mtime
  end)
  return out
end

local function text_of(value)
  if type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), "\n")
  end
  return value ~= nil and value ~= vim.NIL and tostring(value) or ""
end

-- A line of code as it is compared: the spaces at its ends dropped and every
-- run of spaces inside it made one, so a change of indentation or a text
-- copied with its tabs turned to spaces still matches.
function M.squash(text)
  return vim.trim((text:gsub("%s+", " ")))
end

local function is_absolute(path)
  return path:match("^%a:[/\\]") or path:match("^[/\\]") or path:match("^~")
end

local function is_step(record)
  return tonumber(record.line) ~= nil and type(record.file) == "string"
end

-- The id of each step, in order: the one it gives, or its place among the
-- steps. An id written twice names the first step; the second is kept under
-- one of its own.
local function ids_of(steps)
  local ids, known = {}, {}
  for index, record in ipairs(steps) do
    local id = record.id ~= nil and text_of(record.id) or tostring(index)
    if known[id] then
      id = id .. "#" .. index
    end
    known[id] = true
    ids[index] = id
  end
  return ids
end

-- The trace in `path`: its title and steps, each step with an absolute file.
-- Lines that are not JSON, half written as the file grows, are left out.
function M.read(path)
  local trace = { path = path, title = "", steps = {} }
  local file = io.open(path, "r")
  if not file then
    return trace
  end
  local content = file:read("*a")
  file:close()
  local records = {}
  local ok, whole = pcall(vim.json.decode, content)
  if ok and type(whole) == "table" and type(whole.steps) == "table" then
    records = vim.list_extend({ whole }, whole.steps)
  else
    for line in content:gmatch("[^\r\n]+") do
      local fine, record = pcall(vim.json.decode, line)
      if fine and type(record) == "table" then
        records[#records + 1] = record
      end
    end
  end
  local root
  local steps = {}
  for _, record in ipairs(records) do
    if record.line == nil then
      trace.title = record.title and text_of(record.title) or trace.title
      root = record.root and text_of(record.root) or root
    elseif is_step(record) then
      steps[#steps + 1] = record
    end
  end
  root = vim.fs.normalize(root or vim.fn.getcwd())
  trace.root = root
  local ids = ids_of(steps)
  local known = {}
  for index, record in ipairs(steps) do
    local file_path = record.file
    if not is_absolute(file_path) then
      file_path = vim.fs.joinpath(root, file_path)
    end
    local step = {
      id = ids[index],
      file = vim.fs.normalize(file_path),
      line = math.max(1, math.floor(tonumber(record.line))),
      note = text_of(record.note),
      kind = text_of(record.kind),
      text = M.squash(text_of(record.text)),
      edited = record.edited == true,
    }
    step.parent = record.parent ~= nil and text_of(record.parent) or nil
    local title = text_of(record.title)
    step.title = title ~= "" and title or (step.note:match("^[^\n]+") or vim.fs.basename(step.file))
    known[step.id] = true
    trace.steps[#trace.steps + 1] = step
  end
  for _, step in ipairs(trace.steps) do
    if step.parent and (not known[step.parent] or step.parent == step.id) then
      step.parent = nil
    end
  end
  if trace.title == "" then
    trace.title = vim.fn.fnamemodify(path, ":t:r")
  end
  return trace
end

-- The lines of a trace file as records, each with the line it was read from;
-- a file that is one JSON object is taken apart into lines, as it is written
-- back.
local function records_of(path)
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  local ok, whole = pcall(vim.json.decode, content)
  if ok and type(whole) == "table" and type(whole.steps) == "table" then
    local steps = whole.steps
    whole.steps = nil
    local out = { { line = vim.json.encode(whole), record = whole } }
    for _, step in ipairs(steps) do
      out[#out + 1] = { line = vim.json.encode(step), record = step }
    end
    return out
  end
  local out = {}
  for line in content:gmatch("[^\r\n]+") do
    local fine, record = pcall(vim.json.decode, line)
    out[#out + 1] = { line = line, record = fine and type(record) == "table" and record or nil }
  end
  return out
end

local function write_lines(path, lines)
  local file = assert(io.open(path, "w"))
  file:write(table.concat(lines, "\n") .. "\n")
  file:close()
end

-- The step `id` of the trace in `path` given a new title and note, marked as
-- edited; every other line of the file is written back as it was. False when
-- the step is no longer in the file.
function M.edit_step(path, id, title, note)
  local entries = records_of(path)
  local steps = {}
  for _, entry in ipairs(entries) do
    if entry.record and is_step(entry.record) then
      steps[#steps + 1] = entry
    end
  end
  local ids = ids_of(vim.tbl_map(function(entry)
    return entry.record
  end, steps))
  local found = false
  for index, entry in ipairs(steps) do
    if ids[index] == id then
      entry.record.title, entry.record.note, entry.record.edited = title, note, true
      entry.line = vim.json.encode(entry.record)
      found = true
    end
  end
  if found then
    write_lines(
      path,
      vim.tbl_map(function(entry)
        return entry.line
      end, entries)
    )
  end
  return found
end

-- The steps in the order the panel lists them, each under its parent: a row
-- per step with its number in that order, its depth and, for the guides of the
-- tree, whether it is the last of its siblings and whether each of its
-- ancestors is.
function M.outline(trace)
  local children = {}
  for _, step in ipairs(trace.steps) do
    local parent = step.parent or ""
    children[parent] = children[parent] or {}
    table.insert(children[parent], step)
  end
  local rows = {}
  local seen = {}
  local function walk(parent, depth, ancestors_last)
    local list = children[parent] or {}
    for index, step in ipairs(list) do
      if not seen[step.id] then
        seen[step.id] = true
        local last = index == #list
        rows[#rows + 1] = {
          step = step,
          number = #rows + 1,
          depth = depth,
          last = last,
          ancestors_last = ancestors_last,
          has_children = children[step.id] ~= nil,
        }
        local below = vim.list_extend({}, ancestors_last)
        below[#below + 1] = last
        walk(step.id, depth + 1, below)
      end
    end
  end
  walk("", 0, {})
  return rows
end

return M

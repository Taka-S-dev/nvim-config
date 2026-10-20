-- A name typed for a query of GTAGS, where the cursor is on none: the names
-- the project defines, narrowed as they are typed, and the query run on the
-- one chosen. <leader>js on a blank line did nothing, and on the bare " *" of
-- a block comment looked for the star; the word had to be found in the code
-- first.
--
-- Every definition GTAGS knows is read once, and the picker narrows them as
-- <leader>ff narrows files: the words typed, split at spaces, must all be in
-- the name, in any order and loosely, so bio ssl finds BIO_f_ssl; in lower
-- case they match any case, with a capital only that one ('smartcase').
-- global itself lists names only by how they begin, so bio ssl found nothing
-- when the list asked it for each letter typed.
--
-- Each definition is a row of its own, with its file and line beside the name
-- and the lines around it in the preview, so a name defined in two files, as
-- openssl's ssl_servername_cb is in s_client.c and s_server.c, is told apart
-- before one is chosen. The names gtags knows but records no definition of,
-- those from outside the tree such as memcpy and size_t, follow with no file.
local M = {}

-- What was read, by project: the rows, and the GTAGS files they came from as
-- they stood, so a rebuild or `global -u` is read again.
local cache = {} ---@type table<string, { stamp: string, parts: table[][] }>

local function stamp(root)
  local parts = {}
  for _, name in ipairs({ "GTAGS", "GRTAGS" }) do
    local stat = vim.uv.fs_stat(vim.fs.joinpath(root, name))
    parts[#parts + 1] = stat and ("%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or "-"
  end
  return table.concat(parts, " ")
end

-- `global -dx` prints `name  line  path  source-line`, the path from the root.
local function definitions(root, output)
  local rows, named = {}, {}
  for line in vim.gsplit(output or "", "\n", { trimempty = true }) do
    local name, lnum, path, text = line:gsub("\r$", ""):match("^(%S+)%s+(%d+)%s+(%S+)%s?(.*)$")
    if name then
      named[name] = true
      rows[#rows + 1] = {
        text = name,
        name = name,
        path = path,
        file = vim.fs.joinpath(root, path),
        pos = { tonumber(lnum), 0 },
        source = vim.trim(text),
      }
    end
  end
  return rows, named
end

-- Every row under `root`, handed to `part(list, last)` in two lists as they
-- arrive: the definitions, then the other names gtags knows that have none.
local function all(root, part)
  local key = stamp(root)
  local kept = cache[root]
  if kept and kept.stamp == key then
    part(kept.parts[1], false)
    return part(kept.parts[2], true)
  end
  local global = require("taka.lib.gtags_global")
  global.ask(root, { "-dx", ".*" }, function(output)
    local first, named = definitions(root, output)
    part(first, false)
    global.ask(root, { "-cs" }, function(symbols)
      local second = {}
      for name in vim.gsplit(symbols or "", "\n", { trimempty = true }) do
        name = vim.trim(name)
        if name ~= "" and not named[name] then
          named[name] = true
          second[#second + 1] = { text = name, name = name }
        end
      end
      cache[root] = { stamp = key, parts = { first, second } }
      part(second, true)
    end)
  end)
end

M.all = all

-- The name typed whole goes first, where it is one: ssl_read before SSL_read
-- and ssl_read_internal, which the picker scores alike.
local EXACT = 1e6

-- The name, then its file and line in the colour of a comment. The name comes
-- first: the picker marks the letters matched from the start of the row.
local function format(item)
  local ret = { { item.name } }
  if item.path then
    ret[#ret + 1] = { "  " }
    ret[#ret + 1] = { ("%s:%d"):format(item.path, item.pos[1]), "SnacksPickerComment" }
  end
  return ret
end

-- The lines around the definition, or a word on why there are none.
local function preview(ctx)
  if ctx.item.file then
    return Snacks.picker.preview.file(ctx)
  end
  ctx.preview:reset()
  ctx.preview:set_lines({ "No definition recorded: Enter still looks for where it is used." })
end

-- A definition chosen is gone to as <C-]> goes to one: on the tag stack, at
-- the line its text now stands on where the file has moved since the index.
local function jump(item)
  local lookup = require("taka.gtags.lookup")
  local found = lookup.heal({ filename = item.file, lnum = item.pos[1], col = 1, text = item.source })
  lookup.show("Definitions of " .. item.name, item.name, { found })
end

-- Opens the list for the query `kind` (s, c, t and the rest of
-- lua/taka/gtags/lookup.lua), `title` naming it; a name chosen runs it. For
-- "g" the definition chosen is gone to, the row saying which; a name with no
-- definition recorded is looked up as <leader>jg does on a word. A key that is
-- no query of lookup.lua, the peek or the writes list, hands what to do with
-- the name as `on_name` instead.
function M.pick(kind, title, on_name)
  local file = vim.api.nvim_buf_get_name(0)
  local root = require("taka.lib.gtags_global").root(file)
  if not root then
    return vim.notify("No GTAGS for this file. Build one with <leader>jb.", vim.log.levels.WARN)
  end
  return Snacks.picker({
    source = "gtags_names",
    title = title .. ": type a name",
    format = format,
    preview = preview,
    matcher = {
      on_match = function(matcher, item)
        if item.name == vim.trim(matcher.pattern) then
          item.score = item.score + EXACT
        end
      end,
    },
    -- The rows arrive from global later: the finder, run by snacks in a
    -- coroutine of its own, is suspended until each part does and resumed
    -- with it, the definitions shown before the rest are read.
    finder = function()
      return function(cb)
        local async = require("snacks.picker.util.async").running()
        local waiting, last = {}, false
        all(root, function(list, is_last)
          waiting[#waiting + 1] = list
          last = is_last
          if async then
            async:resume()
          end
        end)
        while true do
          while #waiting > 0 do
            for _, row in ipairs(table.remove(waiting, 1)) do
              -- A copy: snacks writes its score onto each item, and the kept
              -- rows serve every list opened after. Given the rows themselves,
              -- a list opened again with nothing typed came up in the order of
              -- the last search, not from the top.
              cb(setmetatable({}, { __index = row }))
            end
          end
          if last or not async then
            return
          end
          async:suspend()
        end
      end
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      end
      if on_name then
        on_name(item.name)
      elseif kind == "g" and item.file then
        jump(item)
      elseif kind == "g" then
        require("taka.gtags").jump(item.name)
      else
        require("taka.gtags").query(kind, item.name)
      end
    end,
  })
end

return M

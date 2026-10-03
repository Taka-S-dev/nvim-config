-- Where a C name is written to (<leader>jw): assigned, assigned with an
-- operator (`+=` and the like), stepped with `++` or `--`, given a value where
-- it is declared, or set in an initializer (`.count = 7`). gtags records no
-- such thing, and cscope's "assignments to this symbol" has no counterpart in
-- it, so the places come from ripgrep and are kept or dropped by the grammar:
-- a line is a write when the syntax tree says the name is what an assignment
-- writes to. That leaves out a comment or a string that only looks like one,
-- `count == 3`, and `s->arr[count] = 5`, which writes to arr and only reads
-- count.
--
-- A member and a variable of the same name are both listed: which one a line
-- writes to is not known from the line, and leaving one out on a guess drops
-- writes without a word. Writes made through a pointer passed away
-- (`memset(&x, ...)`) are not seen.
local M = {}

local QUERY = [[
(assignment_expression left: (_) @lhs)
(update_expression argument: (_) @lhs)
(init_declarator declarator: (_) @declared)
(initializer_pair designator: (field_designator) @designated)
]]
local query

-- The name an assignment writes to, from what stands on its left: the field of
-- `s->count`, the array of `arr[i]` and the pointer of `*p` (as `*p = 0` is
-- what is written through p), and the name of a declarator however it is
-- wrapped (`*name`, `name[4]`).
local function written(node, source)
  local kind = node:type()
  if kind == "identifier" or kind == "field_identifier" then
    return vim.treesitter.get_node_text(node, source), node
  end
  local inner = node:field("field")[1]
    or node:field("declarator")[1]
    or node:field("argument")[1]
    or (kind:find("^parenthesized_") or kind == "field_designator") and node:named_child(0)
  if inner then
    return written(inner, source)
  end
end

-- The writes to `name` on the given lines of a file, read with the grammar.
local function writes_in(file, name, lines)
  local handle = io.open(file, "rb")
  if not handle then
    return {}
  end
  local source = handle:read("*a")
  handle:close()
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "c")
  if not ok then
    return {}
  end
  query = query or vim.treesitter.query.parse("c", QUERY)
  local root = parser:parse()[1]:root()
  local found, seen = {}, {}
  for _, lnum in ipairs(lines) do
    for _, node in query:iter_captures(root, source, lnum - 1, lnum) do
      local target, at = written(node, source)
      if target == name and at then
        local row, col = at:start()
        local key = row .. ":" .. col
        if row == lnum - 1 and not seen[key] then
          seen[key] = true
          found[#found + 1] = { lnum = row + 1, col = col + 1 }
        end
      end
    end
  end
  return found
end

-- The root to look in: the project the file is in, by GTAGS or version
-- control, else the working directory.
local function root_of(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  return require("taka.lib.gtags_global").root(file, { ".git", ".svn" }) or vim.fn.getcwd()
end

-- The writes to `name` under `root`, handed to `done` as quickfix items. The
-- files are read a few at a time, so the editor keeps up while a common name
-- is looked for in a large tree.
function M.find(name, root, done)
  vim.system(
    { "rg", "--vimgrep", "--word-regexp", "--fixed-strings", "-t", "c", "-t", "cpp", "--", name, root },
    { text = true },
    vim.schedule_wrap(function(result)
      local by_file, files = {}, {}
      for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local file, lnum = line:match("^(.-):(%d+):%d+:")
        if file then
          file = vim.fs.normalize(file)
          if not by_file[file] then
            by_file[file] = {}
            files[#files + 1] = file
          end
          local lines = by_file[file]
          if lines[#lines] ~= tonumber(lnum) then
            lines[#lines + 1] = tonumber(lnum)
          end
        end
      end
      table.sort(files)
      local items, index = {}, 0
      local function step()
        local stop = vim.uv.hrtime() + 15e6
        while index < #files and vim.uv.hrtime() < stop do
          index = index + 1
          local file = files[index]
          for _, hit in ipairs(writes_in(file, name, by_file[file])) do
            local text = vim.fn.readfile(file, "", hit.lnum)[hit.lnum] or ""
            items[#items + 1] = { filename = file, lnum = hit.lnum, col = hit.col, text = vim.trim(text) }
          end
        end
        if index < #files then
          vim.schedule(step)
        else
          done(items)
        end
      end
      step()
    end)
  )
end

-- The writes to the word under the cursor, in a list with a preview.
function M.show()
  -- The grammar read is C's. Elsewhere a language server's references, gr in
  -- LazyVim, are the nearest thing.
  if vim.bo.filetype ~= "c" and vim.bo.filetype ~= "cpp" then
    vim.notify("The writes list reads C only; gr lists the references", vim.log.levels.WARN)
    return
  end
  local name = vim.fn.expand("<cword>")
  if not name:match("^[%a_][%w_]*$") then
    vim.notify("No name under the cursor", vim.log.levels.WARN)
    return
  end
  if vim.fn.executable("rg") == 0 then
    vim.notify("rg is not on PATH", vim.log.levels.ERROR)
    return
  end
  local answered = require("taka.lib.activity").begin("writes: " .. name)
  M.find(name, root_of(0), function(items)
    answered(#items == 0 and "nothing found" or ("%d found"):format(#items))
    if #items == 0 then
      vim.notify("No writes to " .. name .. " found", vim.log.levels.WARN)
      return
    end
    vim.fn.setqflist({}, " ", { title = "Writes to " .. name, items = items })
    Snacks.picker.qflist({ title = "Writes to " .. name })
  end)
end

return M

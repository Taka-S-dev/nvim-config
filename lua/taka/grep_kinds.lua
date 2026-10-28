-- The kinds of file the current tab searches (lua/taka/scope.lua), chosen
-- from a list with Alt+e in a grep or a file search: the extensions found
-- under the folder searched, with how many files have each, the most first.
-- Tab picks several; Enter sets them as the tab's until others are, and the
-- search opens again with what was typed kept. Keeping to .c files meant
-- typing `-- -g *.c` after the search, at every search.
--
-- `every kind` takes them off; in a C tree `*.c *.h` comes next, the two
-- read together. The kinds the tab keeps to are marked, in the colour of the
-- statusline's pin, and named in the title.
local M = {}

-- The extensions of the files under `dir` (from `cwd`), with their counts,
-- the most first: rg --files, which leaves out what the grep leaves out.
function M.kinds(cwd, dir)
  local result = vim.system({ "rg", "--files", dir or "." }, { cwd = cwd, text = true }):wait()
  local count = {}
  for line in vim.gsplit(result.stdout or "", "\n", { trimempty = true }) do
    local ext = line:match("%.([%w_]+)%s*$")
    if ext then
      count[ext] = (count[ext] or 0) + 1
    end
  end
  local list = {}
  for ext, n in pairs(count) do
    list[#list + 1] = { ext = ext, count = n }
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.ext < b.ext
  end)
  return list, count
end

-- The rows of the list; `now` the extensions the tab keeps to, marked on the
-- row that is them all, or else on each row of one of them.
local function rows(kinds, count, current, now)
  local list = { { text = "every kind", exts = nil, note = current and ("takes " .. current .. " off") or nil } }
  if count.c and count.h then
    list[#list + 1] = { text = "*.c *.h", exts = { "c", "h" }, note = ("%d files"):format(count.c + count.h) }
  end
  for _, kind in ipairs(kinds) do
    list[#list + 1] = { text = "*." .. kind.ext, exts = { kind.ext }, note = ("%d files"):format(kind.count) }
  end
  if now then
    local key = table.concat(vim.fn.sort(vim.deepcopy(now)), " ")
    local marked = vim.tbl_filter(function(row)
      return row.exts and table.concat(vim.fn.sort(vim.deepcopy(row.exts)), " ") == key
    end, list)
    if #marked == 0 then
      marked = vim.tbl_filter(function(row)
        return row.exts and #row.exts == 1 and vim.tbl_contains(now, row.exts[1])
      end, list)
    end
    for _, row in ipairs(marked) do
      row.now = true
      row.note = row.note .. ", this tab's now"
    end
  end
  return list
end

local function format(item)
  local ret = { { item.text, item.exts and "SnacksPickerFile" or "SnacksPickerDirectory" } }
  if item.note then
    ret[#ret + 1] = { "  " .. item.note, item.now and "DiagnosticInfo" or "SnacksPickerComment" }
  end
  return ret
end

-- The action, in a grep or a file search: lists the kinds, sets those chosen
-- as the tab's, and opens the search again with what was typed.
function M.choose(picker)
  local scope = require("taka.scope")
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local source = picker.opts.source == "files" and "files" or "grep"
  local search = picker.input:get()
  local now = scope.get()
  local kinds, count = M.kinds(cwd, now and now.dir)
  local current = now
      and now.exts
      and table.concat(
        vim.tbl_map(function(e)
          return "*." .. e
        end, now.exts),
        " "
      )
    or nil
  picker:close()
  -- Opened once the search has closed, as the folder list is
  -- (lua/taka/grep_folder.lua): opened at once, it was left in Normal mode.
  vim.schedule(function()
    local chosen = false
    Snacks.picker({
      source = "grep_kinds",
      title = current and ("Kinds of file this tab searches (now " .. current .. "; Tab: several)")
        or "Kinds of file this tab searches (Tab: several)",
      items = rows(kinds, count, current, now and now.exts),
      format = format,
      preview = "none",
      layout = { preset = "select" },
      confirm = function(list, item)
        chosen = true
        local picked = list:selected({ fallback = true })
        list:close()
        local exts, seen = {}, {}
        for _, row in ipairs(picked) do
          if not row.exts then
            exts = nil
            break
          end
          for _, ext in ipairs(row.exts) do
            if not seen[ext] then
              seen[ext] = true
              exts[#exts + 1] = ext
            end
          end
        end
        scope.set_exts(exts)
        scope.reopen(source, search)
      end,
      on_close = function()
        if not chosen then
          vim.schedule(function()
            scope.reopen(source, search)
          end)
        end
      end,
    })
  end)
end

return M

-- A name typed for a query of GTAGS, where the cursor is on none: the names
-- the project defines, listed as they are typed, and the query run on the one
-- chosen. <leader>js on a blank line did nothing, and on the bare " *" of a
-- block comment looked for the star; the word had to be found in the code
-- first.
--
-- global answers a query only for a name given whole, so what is typed cannot
-- be searched for as it is; but `global -c` lists the names a prefix begins,
-- in some sixty milliseconds on openssl, which keeps up with typing. The list
-- is of names only, each a line; Enter runs the query the key was for.
local M = {}

-- Names beginning with `prefix`, handed to `done` as a list: definitions,
-- then the other symbols gtags knows (enum values among them), each once.
-- Two letters at least: one lists thousands, 4306 names beginning with S on
-- openssl.
local function names(root, prefix, done)
  if #prefix < 2 then
    return done({})
  end
  local global = require("taka.lib.gtags_global")
  local out, seen = {}, {}
  local function take(output)
    for name in vim.gsplit(output or "", "\n", { trimempty = true }) do
      name = vim.trim(name)
      if name ~= "" and not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  global.ask(root, { "-c", prefix }, function(definitions)
    take(definitions)
    global.ask(root, { "-cs", prefix }, function(symbols)
      take(symbols)
      -- The name typed whole first, where it is one: ssl_read before
      -- ssl_read_internal, whatever order global lists them in.
      table.sort(out, function(a, b)
        local ea, eb = a == prefix, b == prefix
        if ea ~= eb then
          return ea
        end
        return a < b
      end)
      done(out)
    end)
  end)
end

M.names = names

-- Opens the list for the query `kind` (s, c, t and the rest of
-- lua/taka/gtags/lookup.lua), `title` naming it; a name chosen runs it. For
-- "g" the name chosen is jumped to, as <leader>jg does on a word: a
-- definition is found by its name alone, so no second list is needed.
function M.pick(kind, title)
  local file = vim.api.nvim_buf_get_name(0)
  local root = require("taka.lib.gtags_global").root(file)
  if not root then
    return vim.notify("No GTAGS for this file. Build one with <leader>jb.", vim.log.levels.WARN)
  end
  return Snacks.picker({
    source = "gtags_names",
    title = title .. ": type a name",
    live = true,
    supports_live = true,
    format = "text",
    layout = { preset = "vscode" },
    -- The names arrive from global later: the finder, run by snacks in a
    -- coroutine of its own, is suspended until they do and resumed with them.
    finder = function(_, ctx)
      local prefix = vim.trim(ctx.filter.search)
      return function(cb)
        if not prefix:match("^[%a_][%w_]*$") then
          return
        end
        local async = require("snacks.picker.util.async").running()
        local list
        names(root, prefix, function(found)
          list = found
          if async then
            async:resume()
          end
        end)
        if async and not list then
          async:suspend()
        end
        for _, name in ipairs(list or {}) do
          cb({ text = name })
        end
      end
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      end
      if kind == "g" then
        require("taka.gtags").jump(item.text)
      else
        require("taka.gtags").query(kind, item.text)
      end
    end,
  })
end

return M

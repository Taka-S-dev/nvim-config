-- What each tab page searches: a folder and kinds of file, `ssl/` and `*.c`
-- say, that every grep (<leader>sg, <leader>/, <leader>sw) and every file
-- search (<leader>ff) opened in that tab keeps to, chosen and changed at will:
-- one tab can read a module while another searches the whole project. A
-- folder narrowed to, or options typed after ` -- `, lasted one search, and
-- were chosen or typed again each time.
--
-- Set from inside a search: Alt+. for the folder (lua/taka/grep_folder.lua),
-- Alt+e for the kinds (lua/taka/grep_kinds.lua). :Scope shows it, :Scope off
-- takes both off. A tab that has one says so in the statusline and in the
-- title of each search. A new tab starts with none, and none outlives its
-- tab or the session, so no search starts narrowed unseen.
local M = {}

local MARK = "\u{f08d}" -- nf-fa-thumb_tack

-- The current tab's: { dir = "ssl" or nil, exts = { "c", "h" } or nil }.
function M.get()
  local scope = vim.t.taka_scope
  if type(scope) ~= "table" or (not scope.dir and #(scope.exts or {}) == 0) then
    return nil
  end
  return scope
end

local function store(scope)
  vim.t.taka_scope = (scope.dir or #(scope.exts or {}) > 0) and scope or nil
  vim.cmd.redrawstatus()
end

-- The folder, from the cwd (absolute outside it), or nil for the whole project.
function M.set_dir(dir)
  local scope = vim.deepcopy(M.get() or {})
  scope.dir = dir
  store(scope)
end

-- The extensions, without the dot, or nil for every kind.
function M.set_exts(exts)
  local scope = vim.deepcopy(M.get() or {})
  scope.exts = exts and #exts > 0 and exts or nil
  store(scope)
end

function M.clear()
  vim.t.taka_scope = nil
  vim.cmd.redrawstatus()
end

-- `ssl/ *.c *.h`: the folder, then the kinds.
function M.describe(scope)
  if not scope then
    return ""
  end
  local parts = {}
  if scope.dir then
    parts[#parts + 1] = scope.dir:match("/$") and scope.dir or scope.dir .. "/"
  end
  for _, ext in ipairs(scope.exts or {}) do
    parts[#parts + 1] = "*." .. ext
  end
  return table.concat(parts, " ")
end

-- For the statusline: the current tab's, or "".
function M.status()
  local scope = M.get()
  return scope and (MARK .. " " .. M.describe(scope)) or ""
end

-- The title with the scope, an earlier mark taken off first.
local function titled(title, scope)
  title = vim.trim((title or ""):gsub("%s*" .. vim.pesc(MARK) .. ".*$", ""))
  return scope and (title .. " " .. MARK .. " " .. M.describe(scope)) or title
end

-- The config hook of the grep sources: the folder where rg looks, the
-- project staying its root, and a glob for each kind.
function M.grep(opts)
  -- Once: snacks runs the hook more than once on a search being opened, and
  -- each run added the globs again.
  if opts.taka_scoped then
    return opts
  end
  opts.taka_scoped = true
  local scope = M.get()
  opts.title = titled(opts.title or "Grep", scope)
  if not scope then
    return opts
  end
  if scope.dir and not (opts.dirs and #opts.dirs > 0) then
    opts.dirs = { scope.dir }
  end
  local args = vim.deepcopy(opts.args or {})
  for _, ext in ipairs(scope.exts or {}) do
    vim.list_extend(args, { "-g", "*." .. ext })
  end
  opts.args = args
  return opts
end

-- The config hook of the file search: the folder and the kinds, as fd or rg
-- --files take them.
function M.files(opts)
  if opts.taka_scoped then
    return opts
  end
  opts.taka_scoped = true
  local scope = M.get()
  opts.title = titled(opts.title or "Files", scope)
  if not scope then
    return opts
  end
  if scope.dir and not (opts.dirs and #opts.dirs > 0) then
    opts.dirs = { scope.dir }
  end
  if scope.exts then
    opts.ft = vim.deepcopy(scope.exts)
  end
  return opts
end

-- The search `picker` was, opened again with what was typed in it, the
-- scope as it now is: a grep, or a file search.
function M.reopen(source, search)
  if source == "files" then
    return Snacks.picker.files({ pattern = search })
  end
  return Snacks.picker.grep({ search = search })
end

vim.api.nvim_create_user_command("Scope", function(cmd)
  if cmd.args == "off" then
    M.clear()
    return vim.notify("This tab searches the whole project again")
  end
  local scope = M.get()
  vim.notify(scope and ("This tab searches " .. M.describe(scope)) or "This tab searches the whole project")
end, {
  nargs = "?",
  complete = function()
    return { "off" }
  end,
  desc = "Show what this tab searches, or take it off",
})

return M

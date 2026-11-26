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
--
-- What was last chosen in a project, the folder, the kinds and the grep's
-- buttons, is kept beside the editor's data and put back at once with Alt+b
-- in a search: after a restart they were chosen again from two lists, each
-- read anew, every time. Kept, not put back by itself, for the reason above.
local M = {}

-- Where the last choices of each project are kept; the checks put it
-- elsewhere.
M.store = vim.fs.joinpath(vim.fn.stdpath("data"), "grep_scope")

local function last_path(cwd)
  return vim.fs.joinpath(M.store, vim.fn.sha256(vim.fs.normalize(cwd):lower()):sub(1, 16) .. ".json")
end

-- The last choices made in the project at `cwd` (the current one if nil):
-- { dir, exts, match = { case, word, regex } }, each there once chosen.
function M.last(cwd)
  local handle = io.open(last_path(cwd or vim.fn.getcwd()), "r")
  if not handle then
    return nil
  end
  local ok, data = pcall(vim.json.decode, handle:read("*a"))
  handle:close()
  return ok and type(data) == "table" and data or nil
end

-- `fields` kept as the last choices of the current project, with those
-- kept before that it does not name.
function M.remember(fields)
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local data = M.last(cwd) or {}
  for key, value in pairs(fields) do
    data[key] = value
  end
  data.cwd = cwd
  pcall(vim.fn.mkdir, M.store, "p")
  local path = last_path(cwd)
  local handle = io.open(path .. ".tmp", "w")
  if not handle then
    return
  end
  handle:write(vim.json.encode(data))
  handle:close()
  vim.uv.fs_rename(path .. ".tmp", path)
end

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
  if dir then
    M.remember({ dir = dir })
  end
end

-- The extensions, without the dot, or nil for every kind.
function M.set_exts(exts)
  local scope = vim.deepcopy(M.get() or {})
  scope.exts = exts and #exts > 0 and exts or nil
  store(scope)
  if scope.exts then
    M.remember({ exts = scope.exts })
  end
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

-- The last choices as they would be put back, `ssl/ *.c *.h Aa`, or nil
-- when there are none or they are what the tab and the buttons are now.
function M.last_text()
  local last = M.last()
  if not last then
    return nil
  end
  local now, options = M.get() or {}, require("taka.grep_match").options
  local same = (last.dir or now.dir) == now.dir
    and vim.deep_equal(last.exts or now.exts, now.exts)
    and (not last.match or vim.deep_equal(last.match, options))
  if same then
    return nil
  end
  local parts = { M.describe({ dir = last.dir, exts = last.exts }) }
  local match = last.match or {}
  for _, button in ipairs({ { "case", "Aa" }, { "word", "ab" } }) do
    if match[button[1]] then
      parts[#parts + 1] = button[2]
    end
  end
  if match.regex == false then
    parts[#parts + 1] = "as typed"
  end
  local text = vim.trim(table.concat(parts, " "))
  return text ~= "" and text or nil
end

-- Alt+b in a search: the last choices of the project put back, the folder
-- and the kinds for the tab and the buttons for the grep, and the search
-- opened again with what was typed. A folder gone since is left out.
function M.restore(picker)
  local source = picker.opts.source == "files" and "files" or "grep"
  local search = picker.input:get()
  local last = M.last()
  if not last then
    return vim.notify("Nothing chosen in this project yet: Alt+. for a folder, Alt+e for kinds")
  end
  local dir = last.dir
  if dir and vim.fn.isdirectory(vim.fs.joinpath(vim.fn.getcwd(), dir)) == 0 and vim.fn.isdirectory(dir) == 0 then
    dir = nil
  end
  store({ dir = dir or (M.get() or {}).dir, exts = last.exts or (M.get() or {}).exts })
  if type(last.match) == "table" then
    local options = require("taka.grep_match").options
    for _, name in ipairs({ "case", "word", "regex" }) do
      if type(last.match[name]) == "boolean" then
        options[name] = last.match[name]
      end
    end
  end
  picker:close()
  vim.schedule(function()
    M.reopen(source, search)
  end)
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

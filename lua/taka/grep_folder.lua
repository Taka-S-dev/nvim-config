-- The folder the current tab searches (lua/taka/scope.lua), chosen from a
-- list with Alt+. in a grep or a file search: the folders of the project,
-- narrowed as they are typed as <leader>ff narrows files. Chosen, it is the
-- tab's until another is, and the search opens again under it with what was
-- typed kept. Narrowing meant writing the folder as a glob from the root
-- after `-- -g`, the folder known by heart, and for one search only.
--
-- The folder of the file being read comes first, so that Enter at once
-- searches the module being read, then the whole project, then every folder
-- under it. A tab that keeps to a folder has the whole project first, so that
-- Enter at once takes it off, and that folder is marked where it stands and
-- named in the title, in the colour of the statusline's pin. A path pasted
-- is taken as it is when it names a folder, one outside the project too:
-- absolute or from the cwd, with / or \, in quotes or not, a file's path
-- standing for its folder.
local M = {}

-- `text` made a folder, or nil and why not.
function M.folder(text, cwd, fallback)
  text = vim.trim(text or ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  if text == "" then
    text = fallback or ""
    if text == "" then
      return nil, "No folder given, and no file to take one from"
    end
  end
  -- Only ~ is expanded: expand() would read a % or # in a path pasted as
  -- the name of the current or the other file.
  local path = vim.fs.normalize(text:match("^~") and vim.fn.expand(text) or text)
  if not path:match("^%a:/") and not path:match("^/") then
    path = vim.fs.normalize(vim.fs.joinpath(cwd, path))
  end
  path = path:gsub("/+$", "")
  if vim.fn.filereadable(path) == 1 then
    path = vim.fs.dirname(path)
  end
  if vim.fn.isdirectory(path) == 0 then
    return nil, "No such folder: " .. text
  end
  return path
end

-- How the folder is named in the title: from the cwd where it is under it.
local function label(path, cwd)
  local rel = vim.fs.relpath(cwd, path)
  if rel == "." then
    return nil
  end
  return (rel or path) .. "/"
end

-- The folders under `cwd`, from the cwd, each ending in /: fd's, which
-- leaves out what .gitignore does and is quick on a large tree, or else a
-- walk of the folders.
function M.folders(cwd)
  if vim.fn.executable("fd") == 1 then
    local result = vim.system({ "fd", "--type", "d", "--color", "never" }, { cwd = cwd, text = true }):wait()
    if result.code == 0 then
      local out = {}
      for line in vim.gsplit(result.stdout or "", "\n", { trimempty = true }) do
        line = vim.trim(line):gsub("\\", "/")
        out[#out + 1] = line:match("/$") and line or line .. "/"
      end
      table.sort(out)
      return out
    end
  end
  local out = {}
  for name, kind in vim.fs.dir(cwd, { depth = 20 }) do
    if kind == "directory" and not name:match("^%.") and not name:match("/%.") then
      out[#out + 1] = name:gsub("\\", "/") .. "/"
    end
  end
  table.sort(out)
  return out
end

-- The rows of the list: the file's folder, the project, then the rest; the
-- project first while the tab keeps to `current`.
local function rows(cwd, here, current)
  local list, seen = {}, {}
  local function add(rel, note)
    if rel and not seen[rel] then
      seen[rel] = true
      list[#list + 1] = { text = rel, rel = rel, note = note, now = rel == current }
    end
  end
  local whole = current and "the whole project (takes " .. current .. " off)" or "the whole project"
  if current then
    add("./", whole)
  end
  here = here and label(here, cwd)
  add(here, here == current and "the file's folder, this tab's now" or "the file's folder")
  add("./", whole)
  for _, rel in ipairs(M.folders(cwd)) do
    add(rel, rel == current and "this tab's now" or nil)
  end
  return list
end

local function format(item)
  local ret = { { item.rel, "SnacksPickerDirectory" } }
  if item.note then
    ret[#ret + 1] = { "  " .. item.note, item.now and "DiagnosticInfo" or "SnacksPickerComment" }
  end
  return ret
end

-- The action, in a grep or a file search: lists the folders, sets the one
-- chosen as the tab's, and opens the search again with what was typed.
function M.narrow(picker)
  local scope = require("taka.scope")
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local source = picker.opts.source == "files" and "files" or "grep"
  local search = picker.input:get()
  local main = picker.main and vim.api.nvim_win_is_valid(picker.main) and vim.api.nvim_win_get_buf(picker.main)
  local file = main and vim.bo[main].buftype == "" and vim.api.nvim_buf_get_name(main) or ""
  local here = file ~= "" and vim.fs.dirname(vim.fs.normalize(file)) or nil
  local current = scope.get() and scope.get().dir
  current = current and (current:match("/$") and current or current .. "/")
  picker:close()
  -- Opened once the search has closed: its close leaves Insert mode, and
  -- does so when the key is done, after a list opened at once had entered
  -- it, and what was typed there went in as commands of Normal mode.
  vim.schedule(function()
    local chosen = false
    Snacks.picker({
      source = "grep_folders",
      title = current and ("Folder this tab searches (now " .. current .. ")") or "Folder this tab searches",
      items = rows(cwd, here, current),
      format = format,
      preview = "none",
      layout = { preset = "select" },
      confirm = function(list, item)
        chosen = true
        local typed = list.input:get()
        list:close()
        -- A path pasted or typed in whole is taken as it is, before the row
        -- the letters happen to fit; failing that, the row chosen.
        local path = typed ~= "" and M.folder(typed, cwd) or nil
        if not path and item then
          path = item.rel == "./" and cwd or M.folder(item.rel, cwd)
        end
        if not path then
          vim.notify("No such folder: " .. typed, vim.log.levels.WARN)
        elseif path == cwd then
          scope.set_dir(nil)
        else
          scope.set_dir(vim.fs.relpath(cwd, path) or path)
        end
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

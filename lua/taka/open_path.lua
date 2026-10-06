-- A place in a file opened from the text it is written as (<leader>fo): a path
-- with a line number, copied from what a person or a tool wrote, such as
-- `ssl/d1_srtp.c:60` or `ssl/d1_srtp.c l60`. <leader>ff takes `file:line`
-- typed into it, but not the other ways a line number is written, and opening
-- the file and then going to the line took two steps.
local M = {}

-- The ways a line is written after a path, tried in turn: the path is what
-- comes before. A path on Windows starts with a drive and a colon, which no
-- line number follows, so `C:/src/a.c:12` is the path `C:/src/a.c`.
local FORMS = {
  "^(.-):(%d+):%d+$", -- a.c:12:5
  "^(.-):(%d+)$", -- a.c:12
  "^(.-)%((%d+)%)$", -- a.c(12)
  "^(.-)#L(%d+)$", -- a.c#L12
  "^(.-)%s+[Ll][Ii][Nn][Ee]%s*(%d+)$", -- a.c line 12
  "^(.-)%s+[Ll](%d+)$", -- a.c l12
  "^(.-)%s+(%d+)%s*行目?$", -- a.c 12行目
  "^(.-)%s+(%d+)$", -- a.c 12
}

-- The path and the line number in `text`, its first line with the quotes and
-- backticks around it dropped; the line is nil when none is written.
function M.parse(text)
  text = vim.trim((text or ""):match("[^\r\n]*") or "")
  text = vim.trim(text:gsub("^[`'\"]+", ""):gsub("[`'\"]+$", ""))
  for _, form in ipairs(FORMS) do
    local path, line = text:match(form)
    if path and path ~= "" then
      return vim.trim(path), tonumber(line)
    end
  end
  return text, nil
end

-- The file `path` names: as it is, under the cwd, or under the root of the
-- project the current file is in, the first that is there.
local function find(path)
  path = path:gsub("\\", "/")
  local tried = { path, vim.fs.joinpath(vim.fn.getcwd(), path) }
  local ok, root = pcall(function()
    return LazyVim.root()
  end)
  if ok and root then
    tried[#tried + 1] = vim.fs.joinpath(root, path)
  end
  for _, candidate in ipairs(tried) do
    local stat = vim.uv.fs_stat(candidate)
    if stat and stat.type == "file" then
      return vim.fs.normalize(vim.fn.fnamemodify(candidate, ":p"))
    end
  end
end

-- Opens the place written in `text`, or in the clipboard when no text is
-- given. A file found is opened at the line, centred. One not found is looked
-- for by the end of its path in the list of files, where it may be written
-- from partway down the project; the line goes with it, which the list takes
-- as `file:line`.
function M.open(text)
  if not text or text == "" then
    text = vim.fn.getreg("+")
    if text == "" then
      text = vim.fn.getreg('"')
    end
  end
  local path, line = M.parse(text)
  if path == "" then
    return vim.notify("No path to open: copy one first", vim.log.levels.WARN)
  end
  local file = find(path)
  if file then
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(file))
    if line then
      vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
      vim.cmd("normal! zz")
    end
    return file
  end
  -- The last two parts of the path are enough to find it and few enough to
  -- match a path the writer gave from another folder.
  local parts = vim.split(path:gsub("\\", "/"), "/", { trimempty = true })
  local query = table.concat(vim.list_slice(parts, math.max(#parts - 1, 1)), "/")
  Snacks.picker.files({ pattern = query .. (line and (":" .. line) or "") })
end

vim.api.nvim_create_user_command("OpenPath", function(opts)
  M.open(opts.args)
end, { nargs = "?", desc = "Open a path:line, or the one in the clipboard" })

return M

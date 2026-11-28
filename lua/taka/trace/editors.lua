-- The projects the editors on this machine have open, for whoever writes a
-- trace to find the root to give it (skills/nvim-trace/SKILL.md). Each editor
-- with a screen keeps a file of its own while it runs,
--
--   <data>/open_projects/<pid>.json   {"pid", "project", "file", "time"}
--
-- written when its screen starts, when it is focused and when the project of
-- the file read changes, and taken away when it ends. One left by an editor
-- that ended without its end, as when it was killed, names a process no longer
-- there, and is passed over when read: else an editor closed yesterday was
-- taken for one open now. An editor with no screen, as one run for a check,
-- writes none.
--
-- Read from a shell, the open ones, the one used last first:
--   nvim --headless -c "lua require('taka.trace.editors').list_and_exit()"
local M = {}

function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "open_projects")
end

local function own_file()
  return vim.fs.joinpath(M.dir(), vim.fn.getpid() .. ".json")
end

-- This editor's project and file, written down; `force` writes them again
-- with the time even when they have not changed, as when it is focused. A
-- panel or a list entered is no file, and keeps the project and file of the
-- one read before it.
local written, file
function M.write(force)
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  local special = vim.bo.buftype ~= ""
  if special and not force then
    return
  end
  local project = special and written or require("taka.trace").project()
  if not special then
    file = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  end
  if not force and written == project then
    return
  end
  written = project
  vim.fn.mkdir(M.dir(), "p")
  local record = { pid = vim.fn.getpid(), project = project, file = file or "", time = os.time() }
  -- Written in the background: on a slow disk, or one a virus scanner looks
  -- at, a write held the editor some milliseconds at each return to it.
  local text = vim.json.encode(record) .. "\n"
  vim.uv.fs_open(own_file(), "w", 438, function(err, fd)
    if err or not fd then
      return
    end
    vim.uv.fs_write(fd, text, 0, function()
      vim.uv.fs_close(fd)
    end)
  end)
end

-- Whether the process `pid` is running: a signal of 0 asks, and sends nothing.
local function running(pid)
  return type(pid) == "number" and vim.uv.kill(pid, 0) == 0
end

-- The editors open now, the one used last first: each a record as written.
-- The files of editors no longer running are taken away on the way.
function M.list()
  local out = {}
  if not vim.uv.fs_stat(M.dir()) then
    return out
  end
  for name, kind in vim.fs.dir(M.dir()) do
    if kind == "file" and name:match("^%d+%.json$") then
      local path = vim.fs.joinpath(M.dir(), name)
      local ok, record = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      end)
      if ok and type(record) == "table" and type(record.project) == "string" and running(record.pid) then
        out[#out + 1] = record
      elseif ok and type(record) == "table" and type(record.pid) == "number" and not running(record.pid) then
        -- Left by an editor that was killed: taken away, so they do not
        -- pile up.
        os.remove(path)
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.time or 0) > (b.time or 0)
  end)
  return out
end

-- The editors open now, a line each: the project, the file and how long
-- ago it was used, tab apart. The exit code is 1 when none is.
function M.list_and_exit()
  local now, lines = os.time(), {}
  for _, record in ipairs(M.list()) do
    if record.pid ~= vim.fn.getpid() then
      local minutes = math.floor((now - (record.time or now)) / 60)
      lines[#lines + 1] = ("%s\t%s\t%d min ago"):format(record.project, record.file or "", minutes)
    end
  end
  io.stdout:write(#lines > 0 and (table.concat(lines, "\n") .. "\n") or "no editor is open\n")
  vim.cmd(#lines > 0 and "qa!" or "cquit 1")
end

local group = vim.api.nvim_create_augroup("config_trace_editors", { clear = true })
-- Read on VeryLazy, after the screen has come: then written at once, once
-- the trace that reads this file has been read too.
vim.schedule(function()
  M.write(true)
end)
vim.api.nvim_create_autocmd({ "UIEnter", "FocusGained" }, {
  group = group,
  callback = function()
    M.write(true)
  end,
})
vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
  group = group,
  callback = function()
    M.write(false)
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if written then
      os.remove(own_file())
    end
  end,
})

return M

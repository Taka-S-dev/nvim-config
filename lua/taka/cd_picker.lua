-- Optional: pick the working directory from a fuzzy list, the way fuzzy cd
-- helpers do at the shell prompt.
--
-- The list comes from an external picker, a program that draws itself on the
-- terminal and prints the chosen directory to stdout. It runs in a floating
-- terminal with stdout sent to a temporary file; when it exits, the path in
-- that file becomes the working directory. Leaving the picker without a choice
-- prints nothing and changes nothing.
--
-- Which picker to run is a per-machine choice, made in lua/config/local.lua
-- (not tracked by git):
--   vim.g.cd_picker = {
--     exe = "mypicker",               -- looked up on the PATH
--     dirs = "--dirs",                -- arguments for :C, directories below the cwd
--     files = "--files",              -- arguments for :Cf, prints the file's folder
--     recent = "--recent",            -- arguments for :Zi, recently visited directories
--     query_env = "MYPICKER_QUERY",   -- variable the initial filter is passed in
--   }
-- A mode left out gets no command. Where the variable is not set, or the
-- program is not installed, this file defines nothing: no command, no key, no
-- message. The rest of the config does not refer to it.
local picker = vim.g.cd_picker
if type(picker) ~= "table" or type(picker.exe) ~= "string" or vim.fn.executable(picker.exe) ~= 1 then
  return
end

local function pick(title, args, query)
  local out = vim.fn.tempname()
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(vim.o.columns - 4, math.max(60, math.floor(vim.o.columns * 0.8)))
  local height = math.min(vim.o.lines - 4, math.max(10, math.floor(vim.o.lines * 0.8)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
  })

  vim.fn.jobstart(("%s %s > %s"):format(picker.exe, args, vim.fn.shellescape(out)), {
    term = true,
    -- The filter goes through the environment, so nothing typed after the
    -- command has to survive the shell's quoting.
    env = picker.query_env and { [picker.query_env] = query or "" } or nil,
    on_exit = function(_, code)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      local ok, lines = pcall(vim.fn.readfile, out)
      vim.fn.delete(out)
      local path = ok and vim.trim(lines[1] or "") or ""
      if code ~= 0 or path == "" then
        return
      end
      if vim.fn.isdirectory(path) ~= 1 then
        vim.notify("Not a directory: " .. path, vim.log.levels.WARN)
        return
      end
      vim.cmd.cd(vim.fn.fnameescape(path))
      if vim.fn.executable("zoxide") == 1 then
        vim.system({ "zoxide", "add", "--", path })
      end
      vim.notify("cwd: " .. path)
    end,
  })
  vim.cmd.startinsert()
end

local function command(name, mode, title, key)
  local args = picker[mode]
  if not args then
    return
  end
  vim.api.nvim_create_user_command(name, function(opts)
    if opts.args == "-" then
      if pcall(vim.cmd.cd, "-") then
        vim.notify("cwd: " .. vim.fn.getcwd())
      else
        vim.notify("No previous directory yet", vim.log.levels.WARN)
      end
      return
    end
    pick(title, args, opts.args)
  end, { nargs = "*", desc = title })
  if key then
    vim.keymap.set("n", key, "<cmd>" .. name .. "<cr>", { desc = title })
  end
end

command("C", "dirs", "Change directory (below cwd)", "<leader>fd")
command("Cf", "files", "Change directory (to a file's folder)")
command("Zi", "recent", "Change directory (recent)", "<leader>fD")

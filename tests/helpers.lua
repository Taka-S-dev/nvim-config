-- What every check uses: the check itself, the temporary folders it works
-- in, and the small hands that press keys and write files.

-- Every process started during the run, by executable, for the last check.
local spawned = {}
do
  local real_spawn = vim.uv.spawn
  vim.uv.spawn = function(exe, ...)
    local name = (tostring(exe):match("[^/\\]+$") or tostring(exe)):lower():gsub("%.exe$", "")
    spawned[name] = (spawned[name] or 0) + 1
    return real_spawn(exe, ...)
  end
end

local results = {}
local temp_dirs = {}

local SKIP = {}

local function skip(reason)
  error(setmetatable({ reason = reason }, SKIP))
end

local function check(name, fn)
  local started = vim.uv.hrtime()
  local ok, err = pcall(fn)
  local result = { name = name, status = "ok" }
  if not ok and getmetatable(err) == SKIP then
    result.status, result.detail = "skip", err.reason
  elseif not ok then
    result.status, result.detail = "FAIL", tostring(err)
  end
  result.seconds = (vim.uv.hrtime() - started) / 1e9
  results[#results + 1] = result
end

local function expect(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function temp_dir()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

-- Where the editor sits between checks. It is not a git repository on purpose:
-- gitsigns watches the HEAD of the repository the cwd is in, and moving in and
-- out of one every second or two sent it into starting git without end.
local neutral_dir = temp_dir()

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function need(...)
  for _, exe in ipairs({ ... }) do
    if vim.fn.executable(exe) == 0 then
      skip(exe .. " is not installed")
    end
  end
end

local function run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait(60000)
  expect(result.code == 0, table.concat(cmd, " ") .. " failed: " .. vim.trim(result.stderr or ""))
  return result.stdout or ""
end

local function key(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  expect(type(map.callback) == "function", lhs .. " is not mapped")
  return map.callback
end

local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function reset_editor()
  for _, win in ipairs(floats()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  vim.api.nvim_set_current_dir(neutral_dir)
end

local function c_project()
  local dir = temp_dir()
  write(dir .. "/lib.c", { "int target_fn(void)", "{", "    return 42;", "}" })
  write(dir .. "/main.c", { "int target_fn(void);", "", "int main(void)", "{", "    return target_fn();", "}" })
  return dir
end

return {
  spawned = spawned,
  results = results,
  temp_dirs = temp_dirs,
  SKIP = SKIP,
  skip = skip,
  check = check,
  expect = expect,
  temp_dir = temp_dir,
  neutral_dir = neutral_dir,
  write = write,
  need = need,
  run = run,
  key = key,
  floats = floats,
  press = press,
  reset_editor = reset_editor,
  c_project = c_project,
}

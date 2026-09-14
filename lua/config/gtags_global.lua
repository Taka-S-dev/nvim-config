-- Runs GNU Global asynchronously and hands its output back on the main loop.
--
-- Some Windows builds of global.exe are Cygwin binaries that cannot write to
-- the anonymous pipe a native process such as Neovim gives them: the query
-- exits 0 with empty output, while the same command in a terminal prints its
-- results. They can still write to a regular file handle, and to a file that a
-- Cygwin or Git bash redirects. So a query that comes back empty before any
-- query has produced output is retried through a file, then through bash, and
-- the route that worked is remembered. It is remembered across sessions too:
-- where security software inspects every process start, each attempt on a
-- route known to fail costs seconds.
--
-- Once a route has returned output, an empty answer from it is a real miss and
-- is not retried.
--
-- GTAGSROOT and GTAGSDBPATH are passed with backslashes: the Cygwin build
-- returns nothing for the same path written with forward slashes.
local M = {}

local state_file = vim.fn.stdpath("state") .. "/gtags-transport"
local order = { "direct", "file", "bash" }
local verified = false
local bash ---@type false|{ exe: string, tmp: string, prefix: string }|nil

---@type "direct"|"file"|"bash"|nil
M.transport = nil

local function load_transport()
  if M.transport then
    return
  end
  local ok, lines = pcall(vim.fn.readfile, state_file)
  local saved = ok and lines[1] or nil
  M.transport = (saved == "file" or saved == "bash") and saved or "direct"
end

local function save_transport(name)
  M.transport = name
  if name == "direct" then
    vim.fn.delete(state_file)
  else
    vim.fn.mkdir(vim.fn.fnamemodify(state_file, ":h"), "p")
    vim.fn.writefile({ name }, state_file)
  end
end

local function backslashed(path)
  return (path:gsub("/", "\\"))
end

local function gtags_env(root)
  return { GTAGSROOT = backslashed(root), GTAGSDBPATH = backslashed(root), LANG = "C", LC_ALL = "C" }
end

local function global_exe()
  M.exe = M.exe or vim.fn.exepath("global")
  return M.exe
end

-- Each runner calls `done(output)` on the main loop; output is nil when the
-- route could not be tried at all.
M.runners = {}

function M.runners.direct(root, args, done)
  vim.system(vim.list_extend({ global_exe() }, args), { cwd = root, env = gtags_env(root), text = true }, function(result)
    vim.schedule(function()
      done(result.stdout or "")
    end)
  end)
end

function M.runners.file(root, args, done)
  local tmp = vim.fn.tempname()
  local fd = vim.uv.fs_open(tmp, "w", 420)
  if not fd then
    return done(nil)
  end
  -- uv.spawn replaces the environment wholesale, so carry the current one over.
  local overrides, env = gtags_env(root), {}
  for key, value in pairs(vim.fn.environ()) do
    if overrides[key] == nil then
      env[#env + 1] = key .. "=" .. value
    end
  end
  for key, value in pairs(overrides) do
    env[#env + 1] = key .. "=" .. value
  end
  local handle
  handle = vim.uv.spawn(global_exe(), { args = args, cwd = root, env = env, stdio = { nil, fd, nil } }, function()
    vim.uv.fs_close(fd)
    handle:close()
    vim.schedule(function()
      local ok, lines = pcall(vim.fn.readfile, tmp)
      vim.fn.delete(tmp)
      done(ok and table.concat(lines, "\n") or "")
    end)
  end)
  if not handle then
    vim.uv.fs_close(fd)
    vim.fn.delete(tmp)
    done(nil)
  end
end

local function find_bash(done)
  if bash ~= nil then
    return done(bash)
  end
  local exe = vim.fn.exepath("bash")
  if exe == "" then
    for _, base in ipairs({ vim.env.ProgramFiles, vim.env["ProgramFiles(x86)"], vim.env.ProgramW6432 }) do
      for _, sub in ipairs({ "\\Git\\bin\\bash.exe", "\\Git\\usr\\bin\\bash.exe" }) do
        if exe == "" and base and vim.fn.executable(base .. sub) == 1 then
          exe = base .. sub
        end
      end
    end
  end
  if exe == "" then
    bash = false
    return done(bash)
  end
  -- Where bash's /tmp lives on disk, and how it spells C:\ (/cygdrive/c/ or /c/).
  vim.system({ exe, "-c", [[cygpath -w /tmp; cygpath -u 'C:\']] }, { text = true }, function(result)
    vim.schedule(function()
      local lines = vim.split(vim.trim(result.stdout or ""), "\r?\n")
      if result.code ~= 0 or (lines[1] or "") == "" then
        bash = false
      else
        local prefix = (lines[2] or ""):match("^/cygdrive/") and "/cygdrive/" or "/"
        bash = { exe = exe, tmp = vim.trim(lines[1]), prefix = prefix }
      end
      done(bash)
    end)
  end)
end

local function posix_path(path, prefix)
  path = path:gsub("\\", "/")
  if path:match("^%a:") then
    return prefix .. path:sub(1, 1):lower() .. path:sub(3)
  end
  return path
end

local function sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

function M.runners.bash(root, args, done)
  find_bash(function(b)
    if not b then
      return done(nil)
    end
    local name = ("nvim-gtags-%d-%d.txt"):format(vim.fn.getpid(), vim.uv.hrtime())
    local words = {
      "GTAGSROOT=" .. sh_quote(backslashed(root)),
      "GTAGSDBPATH=" .. sh_quote(backslashed(root)),
      "LANG=C",
      "LC_ALL=C",
      sh_quote(posix_path(global_exe(), b.prefix)),
    }
    for _, arg in ipairs(args) do
      words[#words + 1] = sh_quote(arg)
    end
    local cmd = table.concat(words, " ") .. " > " .. sh_quote("/tmp/" .. name) .. " 2>/dev/null"
    vim.system({ b.exe, "-c", cmd }, { cwd = root }, function()
      vim.schedule(function()
        local file = b.tmp .. "\\" .. name
        local ok, lines = pcall(vim.fn.readfile, file)
        vim.fn.delete(file)
        done(ok and table.concat(lines, "\n") or "")
      end)
    end)
  end)
end

---Run `global <args>` in `root` and call `done(output)` on the main loop.
---@param root string
---@param args string[]
---@param done fun(output: string)
function M.run(root, args, done)
  load_transport()
  local first = M.transport
  M.runners[first](root, args, function(output)
    if output and vim.trim(output) ~= "" then
      verified = true
      return done(output)
    end
    if verified then
      return done("")
    end
    local rest = vim.tbl_filter(function(name)
      return name ~= first
    end, order)
    local function try(i)
      if i > #rest then
        -- Nothing answered. A remembered route that fails is dropped, so the
        -- next query starts from a direct run again.
        if first ~= "direct" then
          save_transport("direct")
        end
        return done("")
      end
      M.runners[rest[i]](root, args, function(retry)
        if retry and vim.trim(retry) ~= "" then
          verified = true
          save_transport(rest[i])
          return done(retry)
        end
        try(i + 1)
      end)
    end
    try(1)
  end)
end

function M.status()
  load_transport()
  return ("gtags: route=%s, confirmed=%s, global=%s"):format(M.transport, tostring(verified), global_exe())
end

-- Forget the learned route, e.g. after installing a different global.exe.
function M.reset()
  verified, bash, M.exe = false, nil, nil
  save_transport("direct")
end

return M

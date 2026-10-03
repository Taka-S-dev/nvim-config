local lookup = require("taka.gtags.lookup")
local gtags_root, begin_lookup = lookup.root, lookup.begin

-- Building and refreshing the indexes, from inside the editor and without
-- stopping it. `:!gtags` holds the editor until it returns, which is a second
-- on openssl and minutes on a kernel tree; here the statusline says what is
-- running and how long it took, the same way it does for a lookup.
--
-- The definitions kept in memory need no clearing: they are dropped when the
-- GTAGS file changes.
-- Keyed by what is being built and where: a gtags build and a ctags build of
-- the same tree may run side by side, two of the same kind may not.
local indexing = {} ---@type table<string, boolean>

local function is_indexing(label, root)
  return indexing[label .. "\n" .. root] == true
end

---@param on_success? fun() runs before the result is reported
local function run_indexer(root, cmd, label, on_success)
  if is_indexing(label, root) then
    vim.notify(("%s: already running in %s"):format(label, root), vim.log.levels.INFO)
    return
  end
  indexing[label .. "\n" .. root] = true
  local finished = begin_lookup(label)
  vim.system(cmd, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      indexing[label .. "\n" .. root] = nil
      if result.code == 0 then
        if on_success then
          on_success()
        end
        local took = finished("done")
        -- A build long enough to look away from also says so when it ends.
        if took >= 3000 then
          vim.notify(("%s: done in %.0f s"):format(label, took / 1000))
        end
      else
        finished("failed")
        local why = vim.trim(result.stderr or "")
        vim.notify(("%s failed (exit %d)\n%s"):format(label, result.code, why), vim.log.levels.ERROR)
      end
    end)
  end)
end

-- A database that exists is rebuilt where it is. A first build has nothing to
-- go by but the cwd, and a GTAGS left in the wrong directory is found again by
-- every file below it, so the directory is shown before anything is written.
local function build_gtags()
  local root = gtags_root()
  if not root then
    root = vim.fn.getcwd()
    -- Asked only when there is something to decide: a second press while the
    -- first build runs goes straight to the notice that it is running.
    if not is_indexing("Building GTAGS", root) then
      local prompt = ("No GTAGS covers this file. Build one in\n%s ?"):format(root)
      if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
        return
      end
    end
  end
  run_indexer(root, { "gtags" }, "Building GTAGS")
end

-- Only the files changed since the last run are read again.
local function update_gtags()
  local root = gtags_root()
  if not root then
    vim.notify("No GTAGS for this file. Build one with <leader>jb.", vim.log.levels.WARN)
    return
  end
  run_indexer(root, { "global", "-u" }, "Updating GTAGS")
end

-- The ctags index, built where the gtags database would be.
--
-- A file that gutentags takes for part of a project (lua/plugins/gutentags.lua)
-- goes through gutentags, so the file it writes is the one it keeps up to date
-- on save. Anywhere else -- the dashboard, a tree that was only unpacked, a
-- directory above several checkouts -- gutentags has no command to give, and
-- that is its limit, not ctags': ctags indexes whatever directory it is handed.
-- So there it is run directly, into the directory that holds GTAGS or, failing
-- that, the cwd, which is shown first. Such a file is not refreshed on save;
-- the key rebuilds it.
local function build_ctags()
  if vim.fn.exists(":GutentagsUpdate") == 2 then
    -- Runs in the background; lua/plugins/gutentags.lua reports its start and
    -- end to the statusline.
    vim.cmd("GutentagsUpdate!")
    return
  end

  local root = gtags_root()
  if not root then
    root = vim.fn.getcwd()
    if not is_indexing("Building ctags", root) then
      local prompt = ("Build a ctags index of everything under\n%s ?"):format(root)
      if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
        return
      end
    end
  end

  -- Written under another name and moved into place, so a reader never sees a
  -- half-written index. The excludes are the ones gutentags is given.
  local cmd = { vim.g.gutentags_ctags_executable or "ctags", "-R", "--tag-relative=yes", "-f", "tags.temp" }
  for _, pattern in ipairs(vim.g.gutentags_ctags_exclude or {}) do
    cmd[#cmd + 1] = "--exclude=" .. pattern
  end
  cmd[#cmd + 1] = "--exclude=tags.temp"
  cmd[#cmd + 1] = "."
  run_indexer(root, cmd, "Building ctags", function()
    vim.uv.fs_rename(vim.fs.joinpath(root, "tags.temp"), vim.fs.joinpath(root, "tags"))
  end)
end

return {
  build_gtags = build_gtags,
  update_gtags = update_gtags,
  build_ctags = build_ctags,
}

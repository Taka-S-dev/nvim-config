-- Checks that can be counted, for after a plugin update.
--
-- Run with bin/test.cmd, or from the config directory:
--   nvim --headless -n -c "luafile tests/run.lua"
-- It exits with the number of failed checks.
--
-- Every check here stands for something that broke once and could not be seen
-- from the code: a plugin update changed what gitsigns counts as a change, a
-- search hung, index files turned up among the matches. What only shows on a
-- real screen -- where the peek window lands, whether a click feels slow -- is
-- not here, because a headless run cannot see it.
--
-- Nothing on the machine is relied on but the tools: each check builds what it
-- needs under a temporary directory and removes it again. A check whose tool is
-- missing is skipped, not failed.

-- The checks are in a file per tool beside this one, run in the order below;
-- helpers.lua holds what they share.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local T = dofile(here .. "/helpers.lua")
local spawned, results, temp_dirs, check, expect, neutral_dir, reset_editor =
  T.spawned, T.results, T.temp_dirs, T.check, T.expect, T.neutral_dir, T.reset_editor

local function run_checks()
  vim.api.nvim_set_current_dir(neutral_dir)
  require("lazy").load({ plugins = { "cscope_maps.nvim", "vim-gutentags", "gitsigns.nvim", "snacks.nvim" } })
  -- The tools and their keys, which a start with a screen sets up on VeryLazy
  -- (lua/config/features.lua) and a headless one never reaches.
  require("config.features")
  -- The keys ask before writing an index to a directory; the answer is yes.
  vim.fn.confirm = function()
    return 1
  end

  for _, file in ipairs({
    "editor",
    "svn",
    "gtags",
    "markdown",
    "writes",
    "clipboard",
    "docs",
    "pins",
    "diff",
    "scope",
    "c_macros",
    "call_tree",
    "lsp",
    "jump_stack",
    "trace",
    "highlight",
  }) do
    dofile(here .. "/" .. file .. ".lua")(T)
  end

  -- A whole run starts a few dozen processes. Thousands mean something feeds
  -- itself: it was gitsigns once, starting git over a thousand times in a few
  -- seconds and leaving a Neovim that would not exit.
  check("nothing starts processes without end", function()
    for name, count in pairs(spawned) do
      expect(count < 300, ("%s was started %d times"):format(name, count))
    end
  end)
end

vim.defer_fn(function()
  local ok, err = pcall(run_checks)
  pcall(reset_editor)
  -- Step out of the directories about to be removed, but not into a repository.
  vim.api.nvim_set_current_dir(vim.fs.dirname(neutral_dir))
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end

  local failed, skipped = 0, 0
  local lines = { "" }
  for _, result in ipairs(results) do
    lines[#lines + 1] = ("%-5s %4.1fs  %s%s"):format(
      result.status,
      result.seconds,
      result.name,
      result.detail and ("\n             " .. result.detail) or ""
    )
    failed = failed + (result.status == "FAIL" and 1 or 0)
    skipped = skipped + (result.status == "skip" and 1 or 0)
  end
  if not ok then
    failed = failed + 1
    lines[#lines + 1] = "FAIL  the run itself stopped: " .. tostring(err)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d checks, %d failed, %d skipped"):format(#results, failed, skipped)
  io.stdout:write(table.concat(lines, "\n") .. "\n")
  io.stdout:flush()
  vim.cmd(failed == 0 and "qa!" or ("cquit " .. failed))
end, 3000)

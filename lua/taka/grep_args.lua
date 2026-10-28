-- The ripgrep options typed after ` -- ` in the grep picker (<leader>sg),
-- searched only once they are whole. The grep runs at each letter typed, and
-- on `ssl -- -g`, the glob not typed yet, rg took the `--` that closes the
-- options for the glob and the search for a path: its output was nothing the
-- picker could read, and a message for each line of it piled up on the
-- screen. An option that takes a value and has none yet is left out until it
-- has one, as is a lone `-`, the start of an option, which rg reads as
-- standard input; an option given whole, `-g *.c`, `--glob=*.c` or `-i`, goes
-- as it was.
local M = {}

-- The options of rg that take the next word for their value.
local VALUED = {}
for _, name in ipairs({
  "-g",
  "--glob",
  "--iglob",
  "-t",
  "--type",
  "-T",
  "--type-not",
  "--type-add",
  "--type-clear",
  "-e",
  "--regexp",
  "-f",
  "--file",
  "-m",
  "--max-count",
  "-A",
  "--after-context",
  "-B",
  "--before-context",
  "-C",
  "--context",
  "-d",
  "--max-depth",
  "-M",
  "--max-columns",
  "-E",
  "--encoding",
  "--max-filesize",
  "-j",
  "--threads",
  "--sort",
  "--sortr",
  "--ignore-file",
  "--pre",
  "--pre-glob",
  "-r",
  "--replace",
  "--path-separator",
}) do
  VALUED[name] = true
end

-- `args` with a last option still waiting for its value taken off.
function M.complete(args)
  local last = args[#args]
  if last and (VALUED[last] or last == "-" or last == "--") then
    args = vim.list_slice(args, 1, #args - 1)
  end
  return args
end

-- Wraps snacks' split of what is typed into the search and rg's options.
function M.setup()
  local util = require("snacks.picker.util")
  if util.taka_grep_args then
    return
  end
  local parse = util.parse
  util.parse = function(str)
    local pattern, args = parse(str)
    return pattern, M.complete(args)
  end
  util.taka_grep_args = true
end

return M

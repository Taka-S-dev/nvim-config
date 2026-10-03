-- The tools this config adds, each set up here: its keys, commands and
-- autocommands. Read once the plugins are up, on VeryLazy
-- (lua/config/lazy.lua), after keymaps.lua and autocmds.lua, which hold only
-- keys and autocommands of the config's own.

-- Several words lit at once, <leader>hh and friends (lua/taka/words.lua).
require("taka.words")

-- The scope line, pinned in place with <leader>jl (lua/taka/scope_pin.lua).
require("taka.scope_pin")

-- Pinned lines with notes, <leader>jm and <leader>jM (lua/taka/pins/).
require("taka.pins")

-- Where a diff differs, in a strip down the right edge (lua/taka/diff/map.lua).
require("taka.diff.map")

-- The two sides of a diff scrolled together by the wheel too (lua/taka/diff/scroll.lua).
require("taka.diff.scroll")

-- The line under the cursor, both sides of it, in a pane below a diff, <leader>uP
-- (lua/taka/diff/pane.lua).
require("taka.diff.pane")

-- q anywhere in a comparison ends it (lua/taka/diff/quit.lua).
require("taka.diff.quit")

-- Call trees from GTAGS, <leader>jh and <leader>jH
-- (lua/taka/call_tree/init.lua).
require("taka.call_tree")

-- The jumps the cursor is inside now, <leader>jy (lua/taka/jump_stack.lua).
require("taka.jump_stack")

-- Where a C name is written to, <leader>jw (lua/taka/writes.lua).
require("taka.writes")

-- Optional :C, :Cf and :Zi; defines nothing where the picker is not installed.
require("taka.cd_picker")

-- Macros and enum values told apart in C, where they are used
-- (lua/taka/c_macros.lua).
require("taka.c_macros")

-- The text selected, lit where else it stands (lua/taka/selection_matches.lua).
require("taka.selection_matches")

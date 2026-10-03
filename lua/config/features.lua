-- The tools this config adds, each set up here: its keys, commands and
-- autocommands. Read once the plugins are up, on VeryLazy
-- (lua/config/lazy.lua), after keymaps.lua and autocmds.lua, which hold only
-- keys and autocommands of the config's own.

-- Several words lit at once, <leader>hh and friends (lua/config/words.lua).
require("config.words")

-- The scope line, pinned in place with <leader>jl (lua/config/scope_pin.lua).
require("config.scope_pin")

-- Pinned lines with notes, <leader>jm and <leader>jM (lua/config/pins.lua).
require("config.pins")

-- Where a diff differs, in a strip down the right edge (lua/config/diff_map.lua).
require("config.diff_map")

-- The two sides of a diff scrolled together by the wheel too (lua/config/diff_scroll.lua).
require("config.diff_scroll")

-- The line under the cursor, both sides of it, in a pane below a diff, <leader>uP
-- (lua/config/diff_pane.lua).
require("config.diff_pane")

-- q anywhere in a comparison ends it (lua/config/diff_quit.lua).
require("config.diff_quit")

-- Call trees from GTAGS, <leader>jh and <leader>jH (lua/config/call_tree.lua).
require("config.call_tree")

-- The jumps the cursor is inside now, <leader>jy (lua/config/jump_stack.lua).
require("config.jump_stack")

-- Where a C name is written to, <leader>jw (lua/config/writes.lua).
require("config.writes")

-- Optional :C, :Cf and :Zi; defines nothing where the picker is not installed.
require("config.cd_picker")

-- Macros and enum values told apart in C, where they are used (lua/config/c_macros.lua).
require("config.c_macros")

-- The text selected, lit where else it stands (lua/config/selection_matches.lua).
require("config.selection_matches")

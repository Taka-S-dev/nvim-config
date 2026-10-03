-- The tools this config adds, each set up here: its keys, commands and
-- autocommands. Read once the plugins are up, on VeryLazy
-- (lua/config/lazy.lua), after keymaps.lua and autocmds.lua, which hold only
-- keys and autocommands of the config's own.

-- A key that calls `fn` of a tool with `...`, the tool looked up when it is
-- pressed.
local function key(mode, lhs, module, fn, desc, ...)
  local args = { ... }
  vim.keymap.set(mode, lhs, function()
    require(module)[fn](unpack(args))
  end, { desc = desc })
end

-- Several words lit at once, <leader>hh and friends (lua/taka/words.lua).
require("taka.words")
key({ "n", "x" }, "<leader>hh", "taka.words", "toggle", "Light this word / put it out")
key("n", "<leader>ho", "taka.words", "toggle_panel", "Lit words panel")
key("n", "<leader>hn", "taka.words", "jump", "Next lit word")
key("n", "<leader>hp", "taka.words", "jump", "Previous lit word", true)
key("n", "<leader>hc", "taka.words", "clear", "Put every word out")

-- The scope line, pinned in place with <leader>jl (lua/taka/scope_pin.lua).
require("taka.scope_pin")
key("n", "<leader>jl", "taka.scope_pin", "toggle", "Pin the scope line")

-- Pinned lines with notes, <leader>jm and <leader>jM (lua/taka/pins/).
require("taka.pins")
key("n", "<leader>jm", "taka.pins", "add", "Pin this line with a note")
key("n", "<leader>jM", "taka.pins", "list", "Find a pin")
key("n", "<leader>jo", "taka.pins", "toggle_panel", "Pins panel (arrange)")

-- Where a diff differs, in a strip down the right edge (lua/taka/diff/map.lua).
require("taka.diff.map")

-- The two sides of a diff scrolled together by the wheel too (lua/taka/diff/scroll.lua).
require("taka.diff.scroll")

-- The line under the cursor, both sides of it, in a pane below a diff, <leader>uP
-- (lua/taka/diff/pane.lua).
require("taka.diff.pane").toggle:map("<leader>uP")

-- q anywhere in a comparison ends it (lua/taka/diff/quit.lua).
require("taka.diff.quit")

-- Call trees from GTAGS, <leader>jh and <leader>jH
-- (lua/taka/call_tree/init.lua).
require("taka.call_tree")
key("n", "<leader>jh", "taka.call_tree", "start", "Call tree: callers", "callers")
key("n", "<leader>jH", "taka.call_tree", "start", "Call tree: callees", "callees")

-- The jumps the cursor is inside now, <leader>jy (lua/taka/jump_stack.lua).
require("taka.jump_stack")
key("n", "<leader>jy", "taka.jump_stack", "toggle", "Jump stack")

-- Where a C name is written to, <leader>jw (lua/taka/writes.lua).
require("taka.writes")
key("n", "<leader>jw", "taka.writes", "show", "Where this name is written to")

-- Optional :C, :Cf and :Zi; defines nothing where the picker is not installed.
require("taka.cd_picker")

-- Macros and enum values told apart in C, where they are used
-- (lua/taka/c_macros.lua).
require("taka.c_macros")

-- The text selected, lit where else it stands (lua/taka/selection_matches.lua).
require("taka.selection_matches")

-- What a comparison of two windows gets beyond Vim's own diff: a strip down
-- the right edge showing where the two differ (map.lua), both sides scrolled
-- together by the wheel too (scroll.lua), a pane below with the change under
-- the cursor from both sides (pane.lua), and q in any of its windows ending it
-- (quit.lua). Each sets itself up when read.

require("taka.diff.map")
require("taka.diff.scroll")
local pane = require("taka.diff.pane")
require("taka.diff.quit")

return {
  -- The pane switched on and off, for a key.
  pane_toggle = pane.toggle,
}

-- Completion in C from GTAGS (lua/taka/gtags/complete.lua): with no language
-- server for C, the menu otherwise offered only the words of the open
-- buffers. The source answers only in C and C++ under a GTAGS, and steps aside
-- for a language server that completes, such as clangd, where one is attached.
--
-- After `->` or `.` with the members known, the words of the buffers and the
-- snippets stay out of the menu: none of them can follow there.
local function not_among_members(context)
  return not require("taka.gtags.blink").offering_members(context)
end

return {
  "saghen/blink.cmp",
  opts = {
    sources = {
      default = { "gtags" },
      providers = {
        gtags = { name = "gtags", module = "taka.gtags.blink" },
        buffer = { should_show_items = not_among_members },
        snippets = { should_show_items = not_among_members },
      },
    },
  },
}

-- The width of an indent taken from each file as it is read. LazyVim indents by
-- two everywhere, and openssl, indented by four, drew two indent guides to a
-- level, and >>, o and = put its lines two columns off.
--
-- A file indented by tabs has them eight wide, as Vim and Linux have them, and
-- indents by a tab: left at LazyVim's two, Linux was laid out a quarter as
-- deep as it is written. A project's .editorconfig still has the last word.
return {
  "NMAC427/guess-indent.nvim",
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    on_tab_options = {
      expandtab = false,
      tabstop = 8,
      softtabstop = 0,
      shiftwidth = 0,
    },
  },
}

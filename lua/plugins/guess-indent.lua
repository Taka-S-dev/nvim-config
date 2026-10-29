-- The width of an indent taken from each file as it is read. LazyVim indents by
-- two everywhere, and openssl, indented by four, drew two indent guides to a
-- level, and >>, o and = put its lines two columns off.
--
-- A file indented by tabs has them four wide, as VS Code shows them, and
-- indents by a tab: left at LazyVim's two, a tab-indented tree was laid out
-- half as deep as there, and at Vim's eight twice as deep, the code of a deep
-- function pushed off to the right. A project's .editorconfig still has the
-- last word.
return {
  "NMAC427/guess-indent.nvim",
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    on_tab_options = {
      expandtab = false,
      tabstop = 4,
      softtabstop = 0,
      shiftwidth = 0,
    },
  },
}

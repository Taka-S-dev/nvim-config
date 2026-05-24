-- aerial.nvim: symbol outline sidebar driven by treesitter (and LSP when
-- available). Useful for navigating large legacy C files where clangd is
-- unavailable — treesitter alone can extract function/macro/struct names.
return {
  "stevearc/aerial.nvim",
  keys = {
    { "<leader>co", "<cmd>AerialToggle<cr>", desc = "Symbols outline (Aerial)" },
    { "<leader>cO", "<cmd>AerialNavToggle<cr>", desc = "Symbols nav popup (Aerial)" },
  },
  opts = {
    backends = { "treesitter", "lsp", "markdown", "asciidoc", "man" },
    layout = {
      min_width = 30,
      placement = "edge",
    },
    show_guides = true,
    filter_kind = false, -- show all symbol kinds (functions, macros, structs, ...)
    autojump = true,
  },
}

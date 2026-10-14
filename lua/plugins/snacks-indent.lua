-- The indent guides drawn thin, with ▏, the left eighth of a cell. A
-- box-drawing │ is drawn by the terminal itself, WezTerm's on by default, and a
-- column of them beside every block read heavy. The line pinned by
-- <leader>jl takes the same.
return {
  "folke/snacks.nvim",
  opts = {
    indent = {
      indent = { char = "▏" },
      scope = { char = "▏" },
    },
  },
}

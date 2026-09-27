-- The block the scope line follows, in C without braces.
--
-- snacks takes a node that is a named field of its parent for part of the
-- parent's construct, not a block of its own. In C the body of an if, for or
-- while is such a field, so a nested if whose outer if has no braces was never
-- a scope: on `if (a) if (b) { ... }` the cursor on the inner if lit up the
-- outer one, from its condition down. Named as blocks here, those bodies get
-- their own line, at their own indent.
return {
  "folke/snacks.nvim",
  opts = {
    scope = {
      treesitter = {
        field_blocks = { "local_declaration", "consequence", "alternative", "body" },
      },
    },
  },
}

-- Markdown is drawn in place: headings stand out, tables get aligned rules and
-- code blocks a background, while the line under the cursor shows its source
-- so it can still be edited. <leader>um turns the rendering off and on.
--
-- This is the rendering part of LazyVim's lang.markdown extra, with the same
-- options. The rest of that extra is left out on purpose. Its browser preview
-- downloads a prebuilt server, an unsigned executable, when it is installed and
-- runs it, which is not for a config to decide on a machine where software has
-- to be approved first. Its language server and linter are further downloads,
-- through Mason, that the rendering does not depend on. This plugin is plain
-- Lua and needs nothing beyond the treesitter parsers this config already
-- installs.
return {
  "MeanderingProgrammer/render-markdown.nvim",
  ft = { "markdown" },
  opts = {
    code = { sign = false, width = "block", right_pad = 1 },
    heading = { sign = false, icons = {} },
    checkbox = { enabled = false },
  },
  config = function(_, opts)
    require("render-markdown").setup(opts)
    Snacks.toggle({
      name = "Render Markdown",
      get = require("render-markdown").get,
      set = require("render-markdown").set,
    }):map("<leader>um")
  end,
}

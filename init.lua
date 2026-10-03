-- machine-specific overrides (git-ignored); loaded before plugins so
-- plugin specs can read vim.g values set there
pcall(require, "config.local")

-- scoop's tools started from the folder of their version, past the junction a
-- session opened over ssh cannot follow; set before any plugin starts one
require("config.scoop_shims")

-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

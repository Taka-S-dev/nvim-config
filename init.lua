-- machine-specific overrides (git-ignored); loaded before plugins so
-- plugin specs can read vim.g values set there
pcall(require, "config.local")

-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- VS Code style navigation history: Alt+Left/Right walks the jumplist.
-- <C-o>/<C-i> are the vim-native bindings; these are added for muscle memory.
vim.keymap.set("n", "<A-Left>", "<C-o>", { desc = "Jump back" })
vim.keymap.set("n", "<A-Right>", "<C-i>", { desc = "Jump forward" })

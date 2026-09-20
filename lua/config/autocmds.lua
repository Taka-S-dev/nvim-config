-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Started on a folder, as `nvim some\dir` or through the Explorer "Send to"
-- menu, Neovim shows that folder in the file tree but keeps the directory it
-- was launched from as the working directory. Find File and Find Text then
-- search somewhere else than the tree shows, often the whole home directory.
-- The folder becomes the working directory, so the tree and the searches agree.
-- LazyVim loads this file before the arguments are opened whenever there are
-- any, so this runs in time without waiting for an event.
if vim.fn.argc() == 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
  vim.cmd.cd(vim.fn.fnameescape(vim.fn.fnamemodify(vim.fn.argv(0), ":p")))
end

-- :grep prints what rg wrote, hundreds of `file:line:col:text` lines, and that
-- text lands in a message window where Enter opens nothing: the list that can
-- be jumped from is the quickfix list, which stays closed. So :grep runs
-- silently and the quickfix window opens once it has results; Enter there
-- opens the match in the window above.
--
-- The abbreviation only rewrites `grep` typed as the whole command so far, so
-- `:silent grep`, `:lgrep` and a search pattern containing the word are left
-- alone.
vim.cmd([[cnoreabbrev <expr> grep (getcmdtype() ==# ':' && getcmdline() ==# 'grep') ? 'silent grep' : 'grep']])
vim.api.nvim_create_autocmd("QuickFixCmdPost", {
  group = vim.api.nvim_create_augroup("grep_quickfix", { clear = true }),
  pattern = "grep",
  command = "cwindow",
})

-- gf follows a Markdown link from anywhere inside it (lua/config/markdown_links.lua).
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("markdown_links", { clear = true }),
  pattern = "markdown",
  callback = function(event)
    require("config.markdown_links").setup(event.buf)
  end,
})

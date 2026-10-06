-- Language servers left out of the ones started for every file.
--
-- mason-lspconfig starts every server installed through mason, whether or not
-- this config asks for it. copilot-language-server, once installed, was
-- attached to every buffer: a Node process of some 220 MB given the contents
-- of each file opened, with nothing in this config to show its suggestions.
-- Turned off here, it stays installed and starts again when this entry goes.
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      copilot = { enabled = false },
    },
  },
}

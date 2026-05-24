-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Share the OS clipboard. With this, `y` puts the yanked text into the
-- Windows clipboard so it can be pasted into other apps with Ctrl+V, and
-- text copied with Ctrl+C elsewhere can be put via `p` here.
vim.opt.clipboard = "unnamedplus"

-- Use `zig cc` for nvim-treesitter parser compilation on Windows.
-- MinGW ld.exe chokes on `\\?\` extended-length paths and tree-sitter CLI
-- passes a clang-style 4-component target triple that zig can't parse.
-- bin/zig-cc.cmd is a wrapper that rewrites the triple; see that file for
-- details. Prerequisite on each Windows machine: `winget install zig.zig`.
if vim.fn.has("win32") == 1 then
  if vim.fn.executable("zig") == 1 then
    vim.env.CC = vim.fn.stdpath("config") .. "\\bin\\zig-cc.cmd"
  else
    vim.schedule(function()
      vim.notify(
        "zig not found on PATH. Install with `winget install zig.zig` so "
          .. "nvim-treesitter can compile parsers via bin/zig-cc.cmd.",
        vim.log.levels.WARN
      )
    end)
  end
end

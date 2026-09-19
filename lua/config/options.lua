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

-- Legacy Japanese sources: detect Shift-JIS (cp932) on load. Neovim's default
-- is `ucs-bom,utf-8,default,latin1`, which has no entry for it, so a cp932
-- comment renders as garbage. Order matters:
--   * ucs-bom stays first, or BOM-tagged UTF-8/UTF-16 files (common output of
--     Visual Studio and Hidemaru) stop being recognized.
--   * utf-8 must precede cp932; cp932 accepts almost any byte sequence and
--     would claim UTF-8 files first.
--   * latin1 last as a catch-all. It is byte-for-byte reversible, so a file
--     that matches nothing still opens and writes back unchanged instead of
--     being mangled through utf-8.
-- `sjis` is deliberately absent: cp932 is a superset, so it is unreachable.
--
-- euc-jp is left out on purpose. Detection takes the first encoding that
-- decodes without error, and every EUC-JP hiragana byte is also a valid cp932
-- halfwidth katakana, so a kanji-free EUC-JP file silently decodes as cp932
-- garbage. An unused candidate is pure misdetection risk; add "euc-jp" after
-- "cp932" only if such files actually turn up.
--
-- For a file detected wrong, reopen it with `:e ++enc=cp932`. To pin a whole
-- tree instead of guessing, set 'fileencodings' from a BufReadPre autocmd in
-- lua/config/local.lua, where machine-specific paths belong.
vim.opt.fileencodings = { "ucs-bom", "utf-8", "cp932", "latin1" }

-- One wheel notch scrolls three lines by default, which turns moving through a
-- long C file into a spin. Ten covers a screen in three notches while still
-- being short enough to read past. Keyboard motions stay the faster route --
-- G, <C-d>, and the tag jumps -- but the wheel should not fight the file.
vim.opt.mousescroll = "ver:10,hor:6"

-- The markers for a trailing space and a full-width space stay on: both are
-- invisible, both survive into a diff or a build error, and a warning only
-- works if it shows while the text is being typed.
--
-- The tab marker is dropped. In a tab-indented tree it lands on nearly every
-- line and buries the other two, and the indentation it marks is already
-- visible as indentation. Two spaces stand in for it, which renders as
-- nothing.
vim.opt.list = true
vim.opt.listchars:append({ tab = "  " })

-- Every rg started from here reads the ripgreprc next to init.lua: :grep, the
-- grep picker and grug-far each build their own command line, and an exclusion
-- kept in one of them is missing from the other two. An rg configuration the
-- machine already has is left in charge.
if not vim.env.RIPGREP_CONFIG_PATH then
  vim.env.RIPGREP_CONFIG_PATH = vim.fn.stdpath("config") .. "/ripgreprc"
end

-- `:grep pattern` with no path never returns on Windows: given no path and an
-- input that is not a terminal, rg searches its standard input, and the pipe
-- Neovim hands it stays open. Pointing the input at NUL makes rg search the
-- current directory, as it does when typed in a terminal. `<NUL` is cmd.exe
-- syntax, so it is left alone under any other shell.
if vim.fn.has("win32") == 1 and vim.o.shell:lower():find("cmd") then
  vim.opt.grepprg = "rg --vimgrep $* <NUL"
end

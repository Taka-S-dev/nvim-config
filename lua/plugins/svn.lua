-- Subversion: change marks in the sign column from vim-signify, and the status,
-- log and revision diffs of lua/taka/svn/init.lua under <leader>v. <leader>g
-- stays git's; ]h / [h are the same keys gitsigns gives a git checkout, which
-- it maps per buffer and so wins where both could apply.
--
-- vim-signify is kept to svn alone, so a git checkout keeps gitsigns' marks
-- and no others. It compares against the working copy's own base and never
-- asks the server. It needs a diff program: Git Bash has one on its PATH, a
-- plain Windows shell does not, and there the one Git for Windows ships is
-- used.
--
-- Only where svn is on the PATH: elsewhere the plugin is not loaded and the
-- <leader>v keys do not exist. Where it is, loaded at start: the marks come
-- from an autocmd on reading a buffer, and a buffer read before that autocmd
-- exists gets none until it is read again.
local function diff_program()
  if vim.fn.executable("diff") == 1 then
    return nil
  end
  local git = vim.fn.exepath("git")
  if git == "" then
    return nil
  end
  -- git.exe sits in Git\cmd or Git\bin; diff.exe in Git\usr\bin.
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(git)))
  local diff = vim.fs.joinpath(root, "usr", "bin", "diff.exe")
  return vim.fn.executable(diff) == 1 and diff or nil
end

return {
  "mhinz/vim-signify",
  cond = vim.fn.executable("svn") == 1,
  lazy = false,
  init = function()
    vim.g.signify_skip = { vcs = { allow = { "svn" } } }
    -- The marks look as gitsigns' do in a git checkout: a coloured bar for
    -- an added or changed line, a triangle where lines were deleted. The
    -- plugin's own are letters coloured only in the background, which the
    -- colour scheme leaves close to invisible.
    vim.g.signify_sign_add = "▎"
    vim.g.signify_sign_change = "▎"
    vim.g.signify_sign_change_delete = "▎"
    vim.g.signify_sign_delete = ""
    vim.g.signify_sign_delete_first_line = ""
    local function colours()
      vim.api.nvim_set_hl(0, "SignifySignAdd", { link = "GitSignsAdd" })
      vim.api.nvim_set_hl(0, "SignifySignChange", { link = "GitSignsChange" })
      vim.api.nvim_set_hl(0, "SignifySignChangeDelete", { link = "GitSignsChange" })
      vim.api.nvim_set_hl(0, "SignifySignDelete", { link = "GitSignsDelete" })
      vim.api.nvim_set_hl(0, "SignifySignDeleteFirstLine", { link = "GitSignsDelete" })
    end
    colours()
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("config_svn_signs", { clear = true }),
      callback = colours,
    })
    local diff = diff_program()
    if diff then
      vim.g.signify_difftool = diff
    elseif vim.fn.executable("diff") ~= 1 then
      vim.schedule(function()
        vim.notify("svn is on the PATH but no diff program is: no change marks", vim.log.levels.WARN)
      end)
    end
    pcall(function()
      require("which-key").add({ { "<leader>v", group = "svn" } })
    end)
  end,
  keys = {
    { "]h", "<plug>(signify-next-hunk)", desc = "Next change (svn)" },
    { "[h", "<plug>(signify-prev-hunk)", desc = "Previous change (svn)" },
    {
      "<leader>vs",
      function()
        require("taka.svn").status_here()
      end,
      desc = "Status of the cwd or the folder selected",
    },
    {
      "<leader>vS",
      function()
        require("taka.svn").status_of_choice()
      end,
      desc = "Status of a folder",
    },
    {
      "<leader>vd",
      function()
        require("taka.svn").diff_file()
      end,
      desc = "Diff the file against base",
    },
    {
      "<leader>vh",
      function()
        require("taka.svn").history()
      end,
      desc = "Log and revision diffs",
    },
    {
      "<leader>vb",
      function()
        require("taka.svn").blame()
      end,
      desc = "Who wrote each line (blame), shown or put away",
    },
    { "<leader>vp", "<cmd>SignifyHunkDiff<cr>", desc = "Show this change" },
    {
      "<leader>vr",
      function()
        require("taka.svn").undo_hunk()
      end,
      desc = "Put this change back (asks)",
    },
  },
}

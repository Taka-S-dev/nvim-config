-- cscope-style navigation for legacy C using GNU Global (gtags) as backend.
--
-- Why not vim-gutentags? Neovim >=0.9 dropped built-in cscope support, so
-- gutentags's `gtags_cscope` module aborts at load. cscope_maps.nvim
-- reimplements the cscope command set in Lua and talks to `gtags-cscope`
-- directly.
--
-- Why a build binding of its own? cscope_maps's `:Cs db build` always
-- appends `-d <file>::<path>` to the build command for cscope semantics, but
-- the `gtags` binary doesn't accept `-d` — leaving it as the configured
-- builder yields "database build failed".
--
-- Why prefix `<leader>j` (not `<leader>c`)? `<leader>c*` is LazyVim's code
-- namespace (format, action, rename, etc.) and would collide.
--
-- Requires `gtags` on PATH (scoop install global, or winget GNU.GLOBAL).

local function gtags()
  return require("taka.gtags")
end

local function query_key(lhs, kind, desc)
  return {
    {
      lhs,
      function()
        gtags().query(kind, gtags().under_cursor(kind))
      end,
      desc = desc,
    },
    {
      lhs,
      function()
        gtags().query(kind, gtags().selected_text())
      end,
      desc = desc,
      mode = "x",
    },
  }
end

-- In a help page <C-]> and Ctrl+click follow the link under the cursor, as
-- Vim's own keys do there: a link such as |cfg-trace| was taken for a name to
-- look up in GTAGS or tags, and the jump went to the top of the page.
local function in_help()
  return vim.bo.buftype == "help"
end

local function follow_link()
  vim.cmd.normal({ vim.keycode("<C-]>"), bang = true })
end

local keys = {
  {
    "<C-]>",
    function()
      if in_help() then
        return follow_link()
      end
      gtags().jump(vim.fn.expand("<cword>"))
    end,
    desc = "Jump to definition",
  },
  {
    "<C-]>",
    function()
      gtags().jump(gtags().selected_text())
    end,
    desc = "Jump to definition",
    mode = "x",
  },
  {
    "<C-LeftMouse>",
    function()
      local mouse = vim.fn.getmousepos()
      if mouse.winid ~= 0 and vim.bo[vim.api.nvim_win_get_buf(mouse.winid)].buftype == "help" then
        vim.api.nvim_set_current_win(mouse.winid)
        vim.api.nvim_win_set_cursor(mouse.winid, { mouse.line, math.max(mouse.column - 1, 0) })
        return follow_link()
      end
      gtags().jump_at_mouse()
    end,
    desc = "Jump to definition (Ctrl+click)",
    mode = { "n", "x" },
  },
  {
    "<leader>jp",
    function()
      gtags().peek(vim.fn.expand("<cword>"))
    end,
    desc = "Peek definition",
  },
  {
    "<leader>jp",
    function()
      gtags().peek(gtags().selected_text())
    end,
    desc = "Peek definition",
    mode = "x",
  },
  {
    "<leader>jb",
    function()
      gtags().build_gtags()
    end,
    desc = "Build gtags DB",
  },
  {
    "<leader>ju",
    function()
      gtags().update_gtags()
    end,
    desc = "Update gtags DB (changed files)",
  },
  {
    "<leader>jB",
    function()
      gtags().build_ctags()
    end,
    desc = "Build ctags",
  },
  {
    "<leader>jg",
    function()
      gtags().jump(vim.fn.expand("<cword>"))
    end,
    desc = "Find global definition",
  },
  {
    "<leader>jg",
    function()
      gtags().jump(gtags().selected_text())
    end,
    desc = "Find global definition",
    mode = "x",
  },
}
for _, k in ipairs({
  { "<leader>js", "s", "Find this symbol" },
  { "<leader>jc", "c", "Find callers" },
  { "<leader>jt", "t", "Find this text string" },
  { "<leader>jf", "f", "Find file" },
  { "<leader>ji", "i", "Find files #including this" },
}) do
  vim.list_extend(keys, query_key(k[1], k[2], k[3]))
end

return {
  "dhananjaylatkar/cscope_maps.nvim",
  event = "VeryLazy",
  init = function()
    -- C identifiers are case-sensitive. With the default "followic" and
    -- LazyVim's ignorecase, the ctags fallback treats SSL_new and ssl_new as the
    -- same tag and stops to ask which one was meant.
    vim.opt.tagcase = "match"

    -- Shows which way global is being started, to tell a missing index from a
    -- global.exe whose output never reaches Neovim.
    -- Reports where the last peek window landed, for when it still covers the
    -- line it was supposed to keep visible.
    vim.api.nvim_create_user_command("GtagsPeekDebug", function()
      vim.notify(gtags().peek_debug())
    end, {})

    -- The last jump: what started it, where the answer came from and how long
    -- it took. A jump that feels slow from one input and quick from another is
    -- either answered from memory in one case only, or slow before the mapping
    -- runs at all; the numbers say which.
    vim.api.nvim_create_user_command("GtagsJumpDebug", function()
      vim.notify(gtags().jump_debug())
    end, {})

    vim.api.nvim_create_user_command("GtagsTransport", function(opts)
      local global = require("taka.lib.gtags_global")
      if opts.args == "reset" then
        global.reset()
      end
      vim.notify(global.status())
    end, {
      nargs = "?",
      complete = function()
        return { "reset" }
      end,
    })
  end,
  keys = keys,
  opts = {
    disable_maps = true,
    cscope = {
      -- cscope_maps binds <C-]> to :Cstag from its own setup, which runs after
      -- the keys above and would win.
      tag = { keymap = false },
      db_file = "./GTAGS",
      exec = "gtags-cscope",
      picker = "snacks",
      skip_picker_for_single_result = true,
      project_rooter = {
        enable = true,
      },
    },
  },
}

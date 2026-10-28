-- What each tab searches (lua/taka/scope.lua): a folder (Alt+.) and kinds of
-- file (Alt+e), chosen in a grep (<leader>sg, <leader>/, <leader>sw) or a file
-- search (<leader>ff) and kept for the tab, every search in it keeping to
-- them. `.` is the key that narrows the file tree to a folder too; e for the
-- extensions. The statusline shows what the current tab keeps to, and the
-- frame of each search names the two keys at its foot.
local keys = {
  ["<a-.>"] = { "scope_folder", mode = { "n", "i" } },
  ["<a-e>"] = { "scope_kinds", mode = { "n", "i" } },
}

local actions = {
  scope_folder = function(picker)
    require("taka.grep_folder").narrow(picker)
  end,
  scope_kinds = function(picker)
    require("taka.grep_kinds").choose(picker)
  end,
}

-- The two keys, named under the frame that carries the search's title: they
-- were found only in the help. In the grey of comments and at the right, so
-- that the frame stays quiet; the keys in pills drew the eye from the list.
local footer = { { " Alt+. folder  Alt+e kinds ", "SnacksPickerComment" } }

local function show_keys(picker)
  local wins = { picker.layout.root }
  vim.list_extend(wins, vim.tbl_values(picker.layout.wins))
  vim.list_extend(wins, vim.tbl_values(picker.layout.box_wins))
  for _, win in ipairs(wins) do
    local tpl = win.meta.title_tpl or win.opts.title
    if type(tpl) == "string" and tpl:find("{title}", 1, true) and win:valid() and win:has_border() then
      win.opts.footer, win.opts.footer_pos = footer, "right"
      vim.api.nvim_win_set_config(win.win, { footer = footer, footer_pos = "right" })
      return
    end
  end
end

local function source(hook)
  return {
    config = function(opts)
      return require("taka.scope")[hook](opts)
    end,
    on_show = show_keys,
    actions = actions,
    win = {
      input = { keys = keys },
      list = { keys = keys },
    },
  }
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        sources = {
          grep = source("grep"),
          grep_word = source("grep"),
          files = source("files"),
        },
      },
    },
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("taka.scope").status()
        end,
        cond = function()
          return require("taka.scope").get() ~= nil
        end,
        color = function()
          return { fg = Snacks.util.color("DiagnosticInfo") }
        end,
      })
    end,
  },
}

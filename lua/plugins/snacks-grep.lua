-- What each tab searches (lua/taka/scope.lua): a folder (Alt+.) and kinds of
-- file (Alt+e), chosen in a grep (<leader>sg, <leader>/, <leader>sw) or a file
-- search (<leader>ff) and kept for the tab, every search in it keeping to
-- them. `.` is the key that narrows the file tree to a folder too; e for the
-- extensions. The statusline shows what the current tab keeps to, and the
-- frame of each search names the two keys at its foot.
--
-- A grep also has the buttons of VS Code's search for how it matches, the
-- case, whole words and the pattern, with VS Code's keys
-- (lua/taka/grep_match.lua). Alt+w is whole words there, so moving between
-- the windows of a search, snacks' Alt+w, is Alt+o too, in every search.
local keys = {
  ["<a-.>"] = { "scope_folder", mode = { "n", "i" } },
  ["<a-e>"] = { "scope_kinds", mode = { "n", "i" } },
}

local grep_keys = vim.tbl_extend("force", keys, {
  ["<a-c>"] = { "grep_case", mode = { "n", "i" } },
  ["<a-w>"] = { "grep_word", mode = { "n", "i" } },
  ["<a-r>"] = { "grep_regex", mode = { "n", "i" } },
})

local actions = {
  scope_folder = function(picker)
    require("taka.grep_folder").narrow(picker)
  end,
  scope_kinds = function(picker)
    require("taka.grep_kinds").choose(picker)
  end,
}

local grep_actions = vim.tbl_extend("force", actions, {
  grep_case = function(picker)
    require("taka.grep_match").toggle(picker, "case")
  end,
  grep_word = function(picker)
    require("taka.grep_match").toggle(picker, "word")
  end,
  grep_regex = function(picker)
    require("taka.grep_match").toggle(picker, "regex")
  end,
})

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

-- A grep finds Japanese in files in Shift-JIS too (lua/taka/grep_encoding.lua).
local function legacy_finder(opts, ctx)
  return require("taka.grep_encoding").finder(opts, ctx)
end

local function source(hook)
  local grep = hook == "grep"
  return {
    finder = grep and legacy_finder or nil,
    config = function(opts)
      opts = require("taka.scope")[hook](opts)
      return grep and require("taka.grep_match").config(opts) or opts
    end,
    on_show = function(picker)
      show_keys(picker)
      if grep then
        require("taka.grep_match").attach(picker)
      end
    end,
    actions = grep and grep_actions or actions,
    win = {
      input = { keys = grep and grep_keys or keys },
      list = { keys = grep and grep_keys or keys },
    },
  }
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        win = {
          input = { keys = { ["<a-o>"] = { "cycle_win", mode = { "n", "i" } } } },
          list = { keys = { ["<a-o>"] = "cycle_win" } },
        },
        sources = {
          grep = source("grep"),
          grep_word = source("grep"),
          grep_buffers = { finder = legacy_finder },
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

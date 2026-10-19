-- The preview of a picker (<leader>ff, <leader>sg and the rest) given room
-- for a long line of C. The default layout splits the window in two halves,
-- so on 200 columns the list and the preview each had 78, and of a line of C
-- indented a few levels only the first half was in sight. The preview takes
-- six tenths now, the list keeping four, and <C-Right> and <C-Left> give it
-- more or less, a twentieth at a time, kept for the pickers opened after; a
-- line still cut off is scrolled sideways with <C-h> and <C-l>, by a quarter
-- of the preview at a time, a step that keeps the place in a long line: half
-- of it lost it, and the one column a press of snacks (zl) is too little to
-- be of use.

-- The preview's share of the width, between a fifth and nine tenths. Kept on
-- a table the checks can read: the module's own state is not reachable from
-- outside, and the layout's node has no width when the preview stands below
-- the list on a narrow screen.
local state = { share = 0.6 }
_G.taka_picker_preview = state
local MIN, MAX, STEP = 0.2, 0.9, 0.05

-- The preview's node in a picker's layout tree, where its width is set.
local function preview_node(box)
  for _, child in ipairs(box) do
    if type(child) == "table" then
      if child.win == "preview" then
        return child
      end
      local found = preview_node(child)
      if found then
        return found
      end
    end
  end
end

-- Below the list, on a narrow screen, the preview has a height and no width:
-- the share is still kept, for a picker opened wide later, and nothing moves.
local function resize_preview(delta)
  return function(picker)
    state.share = math.min(MAX, math.max(MIN, state.share + delta))
    local node = preview_node(picker.layout.opts.layout)
    if node and node.width ~= nil then
      node.width = state.share
      picker.layout:update()
    end
  end
end

local function scroll_preview(left)
  return function(picker)
    local win = picker.preview.win
    if not win:valid() then
      return
    end
    local step = math.max(1, math.floor(vim.api.nvim_win_get_width(win.win) / 4))
    vim.api.nvim_win_call(win.win, function()
      vim.cmd(("normal! %d%s"):format(step, left and "zh" or "zl"))
    end)
  end
end

return {
  "folke/snacks.nvim",
  opts = {
    picker = {
      layout = {
        preset = function()
          return vim.o.columns >= 120 and "wide_preview" or "vertical"
        end,
      },
      layouts = {
        wide_preview = {
          layout = {
            box = "horizontal",
            width = 0.9,
            min_width = 120,
            height = 0.8,
            {
              box = "vertical",
              border = true,
              title = "{title} {live} {flags}",
              { win = "input", height = 1, border = "bottom" },
              { win = "list", border = "none" },
            },
            -- A function, so a picker opened later starts at the share the
            -- keys last set.
            {
              win = "preview",
              title = "{preview}",
              border = true,
              width = function()
                return state.share
              end,
            },
          },
        },
      },
      actions = {
        preview_scroll_left = scroll_preview(true),
        preview_scroll_right = scroll_preview(false),
        preview_wider = resize_preview(STEP),
        preview_narrower = resize_preview(-STEP),
      },
      win = {
        input = {
          keys = {
            ["<c-h>"] = { "preview_scroll_left", mode = { "i", "n" } },
            ["<c-l>"] = { "preview_scroll_right", mode = { "i", "n" } },
            -- The keys the file tree is resized with (lua/plugins/snacks-explorer.lua).
            -- Alt and an arrow are often the terminal's, as in a WezTerm set to
            -- move between its panes with them, and never arrive.
            ["<c-Right>"] = { "preview_wider", mode = { "i", "n" } },
            ["<c-Left>"] = { "preview_narrower", mode = { "i", "n" } },
          },
        },
        list = {
          keys = {
            ["<c-h>"] = "preview_scroll_left",
            ["<c-l>"] = "preview_scroll_right",
            ["<c-Right>"] = "preview_wider",
            ["<c-Left>"] = "preview_narrower",
          },
        },
      },
    },
  },
}

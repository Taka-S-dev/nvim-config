-- How the grep picker matches what is typed, as VS Code's search sets it: the
-- case typed always (Aa, Alt+c), whole words only (ab, Alt+w), and a pattern
-- or the text as it is (.*, Alt+r). Three buttons at the right of the line
-- typed in, lit while on, pressed by a click or by the key. Without them the
-- case went by rg's smart case alone and whole words meant `-- -w` typed
-- after the search; only the pattern had a key, and what it was set to was
-- told by an R in the title only while it was off.
--
-- What <leader>sg and <leader>/ were last set to is kept for the next, as the
-- find bar keeps its own (lua/taka/find.lua). <leader>sw starts as it always
-- has, whole words and the text as it is.
local M = {}

local ns = vim.api.nvim_create_namespace("config_grep_match")

M.options = { case = false, word = false, regex = true }

-- Drawn a space apart, each no wider than its two letters: padded as the
-- find bar's are, the three took a fifth of the line typed in and outweighed
-- the search.
local BUTTONS = {
  { text = "Aa", name = "case" },
  { text = "ab", name = "word" },
  { text = ".*", name = "regex" },
}

-- The flags of rg the two first stand for; the pattern is snacks' own
-- `regex`, which gives rg --fixed-strings when off.
local FLAGS = { case = "--case-sensitive", word = "--word-regexp" }

-- One that is on in the colours of the find bar's; one that is off in the
-- grey of comments, as the keys at the foot of the frame are, so that only
-- what is on draws the eye.
local function colours()
  vim.api.nvim_set_hl(0, "GrepMatchButton", { link = "SnacksPickerComment", default = true })
  local special = vim.api.nvim_get_hl(0, { name = "Special", link = false }).fg
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  vim.api.nvim_set_hl(0, "GrepMatchOn", { fg = normal, bg = special, bold = true, default = true })
end
colours()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("config_grep_match_colours", { clear = true }),
  callback = colours,
})

-- `opts` given the flags and the pattern its `taka_match` says.
local function apply(opts)
  local state = opts.taka_match
  local args = {}
  for _, arg in ipairs(opts.args or {}) do
    if arg ~= FLAGS.case and arg ~= FLAGS.word then
      args[#args + 1] = arg
    end
  end
  for name, flag in pairs(FLAGS) do
    if state[name] then
      args[#args + 1] = flag
    end
  end
  opts.args = args
  opts.regex = state.regex
end

-- The config hook of the grep sources, after the tab's scope.
function M.config(opts)
  if opts.taka_match then
    return opts
  end
  local state = vim.deepcopy(M.options)
  if opts.source == "grep_word" then
    state.word, state.regex = true, false
  end
  opts.taka_match = state
  apply(opts)
  -- The R snacks puts in the title while the pattern is off: the button
  -- says it.
  opts.toggles = vim.tbl_extend("force", opts.toggles or {}, { regex = false })
  return opts
end

-- The buttons at the right end of the line, snacks' count, `3/9` and the
-- like, to their left. Of two marks drawn at the right, the one nearer the
-- start of the line stands further right. snacks puts its count at the start
-- each time it changes, and the buttons, moved along by the letters typed,
-- stood to its left and moved at each digit it gained or lost while a search
-- ran. Kept at the start whatever is typed, they stay at the end.
local MARK = 1

function M.draw(picker)
  local buf = picker.input.win.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local chunks = {}
  for _, button in ipairs(BUTTONS) do
    chunks[#chunks + 1] = { button.text, picker.opts.taka_match[button.name] and "GrepMatchOn" or "GrepMatchButton" }
    chunks[#chunks + 1] = { " " }
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    id = MARK,
    right_gravity = false,
    virt_text = chunks,
    virt_text_pos = "right_align",
  })
end

-- The action of a button or its key: the way of matching turned on or off and
-- the search run again.
function M.toggle(picker, name)
  local state = picker.opts.taka_match
  state[name] = not state[name]
  if picker.opts.source == "grep" then
    M.options[name] = state[name]
  end
  apply(picker.opts)
  M.draw(picker)
  picker.list:set_target()
  picker:find()
end

-- The button under the mouse, read off the screen, where they are drawn
-- whatever the width of the window.
local function button_at(picker, mouse)
  if mouse.winid ~= picker.input.win.win then
    return nil
  end
  local texts = vim.tbl_map(function(button)
    return button.text
  end, BUTTONS)
  local all = table.concat(texts, " ")
  for start = math.max(1, mouse.screencol - #all + 1), mouse.screencol do
    local cells = {}
    for col = start, start + #all - 1 do
      cells[#cells + 1] = vim.fn.screenstring(mouse.screenrow, col)
    end
    if table.concat(cells) == all then
      local offset = mouse.screencol - start
      for _, button in ipairs(BUTTONS) do
        if offset < #button.text then
          return button.name
        end
        offset = offset - #button.text - 1
        if offset < 0 then
          return nil
        end
      end
    end
  end
end

-- The grep open, for the clicks watched for below.
local current ---@type snacks.Picker?

-- The buttons drawn as the search opens, and again when the line typed in is
-- set whole (a search brought back from the history), which takes them off.
-- Quick clicks after the first come as a double click and more, into the
-- line typed in, where the first has put the cursor; they are mapped there,
-- each one press, and do what they did anywhere else.
function M.attach(picker)
  current = picker
  local input = picker.input.win.buf
  vim.schedule(function()
    M.draw(picker)
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = input,
    callback = function()
      if #vim.api.nvim_buf_get_extmarks(input, ns, 0, -1, {}) == 0 then
        M.draw(picker)
      end
    end,
  })
  for _, lhs in ipairs({ "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    vim.keymap.set({ "n", "i" }, lhs, function()
      local name = button_at(picker, vim.fn.getmousepos())
      if not name then
        return lhs
      end
      vim.schedule(function()
        M.toggle(picker, name)
      end)
      return ""
    end, { buffer = input, expr = true, desc = "Press a button, or click" })
  end
end

-- A first click on a button, from whichever window of the search: the click
-- puts the cursor in the line typed in, as it does anywhere on it, and the
-- button is pressed after it. Clicks are watched for, not mapped, as for the
-- find bar (lua/taka/find.lua): a mapping is seen only from the window it is
-- made in, and one in the line typed in as well as this pressed a button
-- twice, on and at once off again. In the list it would also have left a
-- second quick click to the list, where a double click opens the file of the
-- row chosen and closes the search.
local left_mouse = vim.keycode("<LeftMouse>")
vim.on_key(function(key, typed)
  local picker = current
  if picker and picker.closed then
    -- Let go of a search closed, which would otherwise be kept until the next.
    current, picker = nil, nil
  end
  if not picker or (typed ~= "" and typed or key) ~= left_mouse then
    return
  end
  vim.schedule(function()
    local name = button_at(picker, vim.fn.getmousepos())
    if name and not picker.closed then
      M.toggle(picker, name)
    end
  end)
end, ns)

-- For the checks: the buttons as drawn, a lit one in brackets.
function M.shown(picker)
  local mark = vim.api.nvim_buf_get_extmarks(picker.input.win.buf, ns, 0, -1, { details = true })[1]
  local out = {}
  for _, chunk in ipairs(mark and mark[4].virt_text or {}) do
    if chunk[2] then
      out[#out + 1] = chunk[2] == "GrepMatchOn" and ("[" .. chunk[1] .. "]") or chunk[1]
    end
  end
  return table.concat(out, " ")
end

return M

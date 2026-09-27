-- Highlight several words at once, each in its own colour, and step between
-- them. For reading: the three variables of a loop, each lit in a different
-- colour, can be followed down a function without losing one for another,
-- where / and * light one word at a time.
--
--   <leader>hh  light the word under the cursor, or the selection, in the next
--               free colour; on a word that is lit already, put it out
--   <leader>hn  next place any lit word appears     <leader>hp  previous
--   <leader>hc  put every word out
--   <leader>ho  a sidebar listing every place a lit word appears in the open
--               files, by word and file with counts; Enter or a double click
--               on a line jumps, h / l close and open a word or a file, dd
--               puts the word out
--
-- A word is matched whole and with its case; a selection is matched as it
-- stands. The words are lit in every window, and stay lit until put out.
local M = {}

local colours = {
  { fg = "#1b1d2b", bg = "#ffc777" }, -- yellow
  { fg = "#1b1d2b", bg = "#c3e88d" }, -- green
  { fg = "#1b1d2b", bg = "#86e1fc" }, -- cyan
  { fg = "#1b1d2b", bg = "#c099ff" }, -- magenta
  { fg = "#1b1d2b", bg = "#ff966c" }, -- orange
  { fg = "#1b1d2b", bg = "#82aaff" }, -- blue
}
for index, colour in ipairs(colours) do
  vim.api.nvim_set_hl(0, "Word" .. index, vim.tbl_extend("keep", { default = true }, colour))
end

-- Lit words in the order they were lit: { pattern = ..., colour = index, label = text }.
local words = {}
local panel_refresh

local function pattern_of(text, whole)
  local literal = vim.fn.escape(text, [[\]])
  return [[\V]] .. (whole and ([[\<]] .. literal .. [[\>]]) or literal)
end

-- Matches are per window; every window carries the list, and one that has
-- not seen a word yet gets it on entry.
local function apply(win)
  local have = vim.w[win].words or {}
  local ids = {}
  for _, word in ipairs(words) do
    ids[word.pattern] = have[word.pattern]
      or vim.fn.matchadd("Word" .. word.colour, word.pattern, 10, -1, { window = win })
  end
  for pattern, id in pairs(have) do
    if not ids[pattern] then
      pcall(vim.fn.matchdelete, id, win)
    end
  end
  vim.w[win].words = ids
end

local function apply_everywhere()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    apply(win)
  end
end

local function selection()
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  local text = vim.fn.getregion(from, to, { type = vim.fn.mode() })
  return table.concat(text, "\n")
end

function M.toggle()
  local text, whole
  if vim.fn.mode():match("^[vV\22]") then
    text, whole = selection(), false
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  else
    text, whole = vim.fn.expand("<cword>"), true
  end
  if text == "" or text:find("\n") then
    return
  end
  local pattern = pattern_of(text, whole)
  for index, word in ipairs(words) do
    if word.pattern == pattern then
      table.remove(words, index)
      apply_everywhere()
      panel_refresh()
      return
    end
  end
  local used = {}
  for _, word in ipairs(words) do
    used[word.colour] = true
  end
  local colour = 1
  while used[colour] and colour < #colours do
    colour = colour + 1
  end
  words[#words + 1] = { pattern = pattern, colour = colour, label = text }
  apply_everywhere()
  panel_refresh()
end

function M.clear()
  words = {}
  apply_everywhere()
  panel_refresh()
end

function M.jump(backwards)
  if #words == 0 then
    vim.notify("No words are lit (<leader>hh lights one)")
    return
  end
  local patterns = {}
  for _, word in ipairs(words) do
    patterns[#patterns + 1] = word.pattern
  end
  vim.cmd("normal! m'")
  if vim.fn.search(table.concat(patterns, [[\|]]), backwards and "bw" or "w") == 0 then
    vim.notify("No lit word found")
  end
end

-- Every place a lit word appears in the files that are open, in a sidebar on
-- the right, laid out as a search result is: the word, in its colour and with
-- its count, then each file, then the lines, with the match coloured in the
-- text. Enter or a double click on a line jumps there; h and l close and open
-- a word or a file; dd puts the word out. The list follows the words as they
-- are lit and put out, and the files as they are opened, closed and edited.
local panel ---@type snacks.Picker?
local closed = {} ---@type table<string, boolean>

local function tree_look()
  local tree = {}
  pcall(function()
    tree = Snacks.picker.config.get().icons.tree
  end)
  return { vertical = tree.vertical or "│ ", middle = tree.middle or "├╴", last = tree.last or "└╴" }
end

-- Items in tree order: a word, its files, their lines. Each carries `parent`,
-- which the matcher keeps a match's ancestors by while a filter is typed,
-- and `sort`, which holds the rows in tree order whatever their score.
local function occurrences(filtering)
  local items = {}
  local function add(item)
    item.sort = ("%06d"):format(#items + 1)
    items[#items + 1] = item
    return item
  end
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and name ~= "" then
      buffers[#buffers + 1] = { buf = buf, name = name }
    end
  end
  table.sort(buffers, function(a, b)
    return a.name < b.name
  end)
  for _, word in ipairs(words) do
    local regex = vim.regex(word.pattern)
    local files = {}
    for _, buffer in ipairs(buffers) do
      local lines = {}
      for number, line in ipairs(vim.api.nvim_buf_get_lines(buffer.buf, 0, -1, false)) do
        local from, to = regex:match_str(line)
        if from then
          lines[#lines + 1] = { number = number, line = line, from = from, to = to }
        end
      end
      if #lines > 0 then
        files[#files + 1] = { name = buffer.name, lines = lines }
      end
    end
    local count = 0
    for _, file in ipairs(files) do
      count = count + #file.lines
    end
    local word_item = add({ kind = "word", word = word, count = count, text = word.label, key = word.pattern })
    local word_open = not closed[word.pattern] or filtering
    for f, file in ipairs(files) do
      local file_item = {
        kind = "file",
        word = word,
        file = file.name,
        parent = word_item,
        last = f == #files,
        text = word.label .. " " .. file.name,
        key = word.pattern .. " " .. file.name,
        count = #file.lines,
      }
      if word_open then
        add(file_item)
      end
      local file_open = not closed[file_item.key] or filtering
      for l, at in ipairs(file.lines) do
        if word_open and file_open then
          add({
            kind = "line",
            word = word,
            file = file.name,
            pos = { at.number, at.from },
            match = { at.from, at.to },
            line = at.line,
            parent = file_item,
            last = l == #file.lines,
            file_last = file_item.last,
            text = word.label .. " " .. file.name .. " " .. at.line,
          })
        end
      end
    end
  end
  return items
end

local function row_text(item, look)
  local pill = { " " .. item.word.label .. " ", "Word" .. item.word.colour }
  if item.kind == "word" then
    return { { closed[item.key] and "+ " or "- " }, pill, { ("  %d"):format(item.count), "Comment" } }
  end
  if item.kind == "file" then
    return {
      { item.last and look.last or look.middle, "SnacksPickerTree" },
      { (closed[item.key] and "+ " or "- ") .. vim.fs.basename(item.file), "Directory" },
      { ("  %d"):format(item.count), "Comment" },
    }
  end
  local line = item.line
  local lead = #line:match("^%s*")
  local from, to = item.match[1], item.match[2]
  return {
    { item.file_last and "  " or look.vertical, "SnacksPickerTree" },
    { item.last and look.last or look.middle, "SnacksPickerTree" },
    { ("%d"):format(item.pos[1]), "LineNr" },
    { " " },
    { line:sub(lead + 1, from) },
    { line:sub(from + 1, to), "Word" .. item.word.colour },
    { line:sub(to + 1) },
  }
end

function panel_refresh()
  if panel and not panel.closed then
    panel:find()
  end
end

local function put_out(word)
  for index, lit in ipairs(words) do
    if lit == word then
      table.remove(words, index)
    end
  end
  apply_everywhere()
  panel_refresh()
end

function M.toggle_panel()
  if panel and not panel.closed then
    panel:close()
    panel = nil
    return
  end
  local look = tree_look()
  local searching = false
  local function fold(state)
    return function(picker, item)
      if not item or item.kind == "line" then
        return
      end
      if state == nil then
        closed[item.key] = not closed[item.key] or nil
      else
        closed[item.key] = state or nil
      end
      picker:find()
    end
  end
  panel = Snacks.picker({
    source = "words",
    title = "Lit words",
    finder = function(_, ctx)
      local filtering = not ctx.filter:is_empty()
      ctx.picker.matcher.opts.keep_parents = filtering
      return occurrences(filtering)
    end,
    format = function(item)
      return row_text(item, look)
    end,
    filter = {
      transform = function(_, filter)
        local now = not filter:is_empty()
        if searching ~= now then
          searching = now
          return true
        end
      end,
    },
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "sort" } },
    focus = "list",
    auto_close = false,
    jump = { close = false },
    layout = { preset = "sidebar", preview = false, layout = { position = "right" } },
    on_close = function()
      panel = nil
    end,
    confirm = function(picker, item)
      if not item then
        return
      end
      if item.kind ~= "line" then
        fold()(picker, item)
        return
      end
      if picker.main and vim.api.nvim_win_is_valid(picker.main) then
        vim.api.nvim_set_current_win(picker.main)
      end
      vim.cmd("normal! m'")
      vim.cmd.edit(vim.fn.fnameescape(item.file))
      vim.api.nvim_win_set_cursor(0, { item.pos[1], item.pos[2] })
    end,
    actions = {
      word_out = function(_, item)
        if item then
          put_out(item.word)
        end
      end,
      words_close = fold(true),
      words_open = fold(false),
    },
    win = {
      list = {
        keys = {
          ["<2-LeftMouse>"] = "confirm",
          ["dd"] = "word_out",
          ["h"] = "words_close",
          ["l"] = "words_open",
        },
      },
    },
  })
end

-- Files come and go, and their lines change.
vim.api.nvim_create_autocmd({ "BufWinEnter", "BufDelete", "BufWritePost" }, {
  group = vim.api.nvim_create_augroup("config_words_panel", { clear = true }),
  callback = function()
    vim.schedule(panel_refresh)
  end,
})

vim.keymap.set({ "n", "x" }, "<leader>hh", M.toggle, { desc = "Light this word / put it out" })
vim.keymap.set("n", "<leader>ho", M.toggle_panel, { desc = "Lit words panel" })
vim.keymap.set("n", "<leader>hn", M.jump, { desc = "Next lit word" })
vim.keymap.set("n", "<leader>hp", function()
  M.jump(true)
end, { desc = "Previous lit word" })
vim.keymap.set("n", "<leader>hc", M.clear, { desc = "Put every word out" })

vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("config_words", { clear = true }),
  callback = function()
    apply(vim.api.nvim_get_current_win())
  end,
})

return M

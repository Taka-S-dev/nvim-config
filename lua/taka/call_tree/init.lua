-- The call tree of a function, in a panel on the right: who calls it and who
-- calls those (<leader>jh), or what it calls and what those call (<leader>jH);
-- t in the panel turns it the other way round. A branch is looked up when it
-- is opened and not before, so the tree of a function called from everywhere
-- costs no more than the rows on show.
--
-- What calls what comes from a source, the first in M.sources that can answer
-- for the buffer; this file is the tree and the panel, and knows of none of
-- them. A source is a module with
--
--   attach(buf)           a session for the buffer, or nil and why not
--
-- and a session has
--
--   session:start(direction, done)
--       done(node) with the function the tree starts from, the one under or
--       around the cursor, or done(nil, why)
--   session:children(node, direction, done, progress)
--       done(nodes) with the callers or callees of a node; progress(text)
--       says how far a slow answer has got
--   session:branches(node, direction)
--       whether a node of its kind can have children that way at all
--   session.unknown
--       the note for a node of kind "unknown", such as "not in GTAGS"
--
-- A node, as a source makes it:
--
--   name          what the row shows
--   kind          "function", "macro", "file" (a place in no function) or
--                 "unknown" (no definition known); colours the name
--   file, lnum    where it is defined, or where it stands
--   sites         { file, lnum } of the calls that link it to the row above;
--                 Enter goes to the first
--   others        how many more definitions its name has, if any
--
-- Anything else on a node is the source's own. The tree adds parent, open,
-- children, loading and the like, and marks a function already among those
-- above it, which is not opened again.
local M = {}

-- Where the call trees come from, in order of preference.
M.sources = { "taka.call_tree.gtags", "taka.call_tree.lsp" }

-- What the panel shows: where it comes from, the function the tree starts
-- from and which way it goes.
local panel = {} ---@type { picker: table?, session: table, direction: "callers"|"callees", top: table }

local function is_ancestor(node, name)
  local up = node
  while up do
    if up.name == name then
      return true
    end
    up = up.parent
  end
  return false
end

local function can_open(node)
  return panel.session:branches(node, panel.direction)
    and not node.recursive
    and not (node.children and #node.children == 0)
end

local tree_look = require("taka.lib.sidebar").tree_look

-- The rows on show, the tree walked through its open branches.
local function rows()
  local out = {}
  local function walk(node, trail)
    out[#out + 1] = { node = node, trail = trail }
    if node.open and node.children then
      for index, sub in ipairs(node.children) do
        local below = vim.list_extend({}, trail)
        below[#below + 1] = index == #node.children
        walk(sub, below)
      end
    end
  end
  walk(panel.top, {})
  return out
end

local MARK = { closed = "▸ ", open = "▾ ", leaf = "  ", loading = "… " }
local NAME = { ["function"] = "Function", macro = "CMacro", file = "Directory", unknown = "Comment", other = "Comment" }

local function row_text(row, look)
  local node = row.node
  local guides = ""
  for level = 1, #row.trail - 1 do
    guides = guides .. (row.trail[level] and "  " or look.vertical)
  end
  if #row.trail > 0 then
    guides = guides .. (row.trail[#row.trail] and look.last or look.middle)
  end
  local mark = node.loading and MARK.loading or can_open(node) and (node.open and MARK.open or MARK.closed) or MARK.leaf
  local notes = {}
  if node.sites and #node.sites > 1 then
    notes[#notes + 1] = "×" .. #node.sites
  end
  if node.recursive then
    notes[#notes + 1] = "↻"
  end
  if node.kind == "macro" then
    notes[#notes + 1] = "macro"
  elseif node.kind == "unknown" and panel.session.unknown then
    notes[#notes + 1] = panel.session.unknown
  end
  if node.others and node.others > 0 then
    notes[#notes + 1] = ("+%d of this name"):format(node.others)
  end
  -- Opened and found empty, so that it does not read as a key that did nothing.
  if node.children and #node.children == 0 then
    notes[#notes + 1] = panel.direction == "callers" and "no callers" or "calls nothing"
  end
  if node.stopped then
    notes[#notes + 1] = ("opened until %d rows"):format(node.stopped)
  end
  if node.loading and node.progress then
    notes[#notes + 1] = node.progress
  end
  local site = node.sites and node.sites[1] or node
  local place = site.file and ("%s:%d"):format(vim.fs.basename(site.file), site.lnum) or ""
  return {
    { guides, "SnacksPickerTree" },
    { mark, "SnacksPickerTree" },
    { node.name, NAME[node.kind] },
    { #notes > 0 and ("  " .. table.concat(notes, "  ")) or "", "Comment" },
    {
      col = 0,
      virt_text = { { " " }, { place, "Comment" }, { " " } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    },
  }
end

local function is_open()
  return panel.picker ~= nil and not panel.picker.closed
end

-- The rows read again with the cursor kept on `focus`, or on the row it was
-- on (lua/taka/lib/sidebar.lua).
local function refresh(focus)
  if not is_open() then
    return
  end
  local picker = panel.picker
  local current = picker:current()
  focus = focus or (current and current.node)
  local target
  if picker.input.filter:is_empty() then
    for index, row in ipairs(rows()) do
      if row.node == focus then
        target = index
      end
    end
  end
  require("taka.lib.sidebar").refresh(picker, target, function(item)
    return item.node == focus
  end)
end

-- A branch opened, its rows looked up the first time. `quiet` leaves the
-- panel to be drawn by the caller, which opens many at once.
function M.expand(node, done, quiet)
  done = done or function() end
  local draw = quiet and function() end or refresh
  if not can_open(node) then
    return done()
  end
  node.open = true
  if node.children or node.loading then
    draw(node)
    return done()
  end
  node.loading = true
  draw(node)
  local session, direction = panel.session, panel.direction
  session:children(node, direction, function(children)
    node.loading, node.progress = false, nil
    if panel.session == session and panel.direction == direction then
      for _, sub in ipairs(children) do
        sub.parent = node
        sub.recursive = sub.kind ~= "file" and is_ancestor(node, sub.name)
      end
      node.children = children
    end
    draw(node)
    done()
  end, function(text)
    node.progress = text
    draw(node)
  end)
end

-- How far L opens below a row, and how many rows it adds before it stops:
-- callers multiply a level at a time, and the first level of a function
-- called from everywhere is hundreds of rows already.
M.limits = { depth = 3, rows = 300 }

-- Every branch below `node` opened, M.limits.depth levels down, a level at a
-- time and one branch after another, with the panel drawn again every few
-- branches.
function M.expand_all(node, done)
  done = done or function() end
  local queue, added, opened = { { node = node, depth = 0 } }, 0, 0
  node.stopped = nil
  local function step()
    local entry = table.remove(queue, 1)
    if not entry then
      refresh(node)
      return done()
    end
    M.expand(entry.node, function()
      opened = opened + 1
      for _, sub in ipairs(entry.node.open and entry.node.children or {}) do
        added = added + 1
        if entry.depth + 1 < M.limits.depth and can_open(sub) then
          if added < M.limits.rows then
            table.insert(queue, { node = sub, depth = entry.depth + 1 })
          else
            node.stopped = M.limits.rows
          end
        end
      end
      if opened % 10 == 0 then
        refresh(node)
      end
      step()
    end, true)
  end
  step()
end

local function toggle(node)
  if node.open and node.children and #node.children > 0 then
    node.open = false
    refresh(node)
  else
    M.expand(node)
  end
end

local function collapse(node)
  if node.open and node.children and #node.children > 0 then
    node.open = false
    refresh(node)
  elseif node.parent then
    node.parent.open = false
    refresh(node.parent)
  end
end

local function jump(node, to_definition)
  local place = (not to_definition and node.sites and node.sites[1]) or node
  if not place.file then
    vim.notify("No definition is known for " .. node.name, vim.log.levels.WARN)
    return
  end
  local picker = panel.picker
  if picker and picker.main and vim.api.nvim_win_is_valid(picker.main) then
    vim.api.nvim_set_current_win(picker.main)
  end
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(place.file))
  vim.api.nvim_win_set_cursor(0, { place.lnum, 0 })
  vim.cmd("normal! ^zz")
end

-- Whether byte `column` of a row of the list, as getmousepos() gives it, is on
-- its ▸ or ▾. Each mark is looked for whole: `[▸▾]` would be a set of bytes,
-- and the first byte of either is the first byte of the guide ├ too.
function M.on_mark(line, column)
  local at = line:find(MARK.closed, 1, true) or line:find(MARK.open, 1, true)
  return at ~= nil and column >= at and column < at + #MARK.open
end

-- The tree from `top` shown, opened one level.
local function open_tree(session, direction, top)
  if is_open() then
    panel.picker:close()
  end
  panel.session, panel.direction, panel.top = session, direction, top
  local look = tree_look()
  require("taka.lib.sidebar").make_room()
  panel.picker = Snacks.picker({
    source = "call_tree",
    title = (direction == "callers" and "Callers of " or "Callees of ") .. top.name,
    finder = function(_, ctx)
      ctx.picker.matcher.opts.keep_parents = not ctx.filter:is_empty()
      local items, by_node = {}, {}
      for index, row in ipairs(rows()) do
        local item = {
          text = row.node.name,
          node = row.node,
          row = row,
          parent = row.node.parent and by_node[row.node.parent],
          sort = ("%06d"):format(index),
        }
        by_node[row.node] = item
        items[#items + 1] = item
      end
      return items
    end,
    format = function(item)
      return row_text(item.row, look)
    end,
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "sort" } },
    focus = "list",
    auto_close = false,
    jump = { close = false },
    layout = require("taka.lib.sidebar").layout(),
    on_close = function()
      panel.picker = nil
    end,
    confirm = function(_, item)
      if item then
        jump(item.node)
      end
    end,
    actions = {
      call_open = function(_, item)
        if item then
          M.expand(item.node)
        end
      end,
      call_close = function(_, item)
        if item then
          collapse(item.node)
        end
      end,
      call_open_all = function(_, item)
        if item then
          M.expand_all(item.node)
        end
      end,
      call_definition = function(_, item)
        if item then
          jump(item.node, true)
        end
      end,
      -- The same function the other way round, as a tree of its own.
      call_turn = function()
        local turned = { name = top.name, kind = top.kind, file = top.file, lnum = top.lnum, others = top.others }
        open_tree(session, direction == "callers" and "callees" or "callers", turned)
      end,
    },
    win = {
      list = {
        keys = {
          ["l"] = { "call_open", desc = "Open the branch" },
          ["<Right>"] = { "call_open", desc = "Open the branch" },
          ["h"] = { "call_close", desc = "Close the branch" },
          ["<Left>"] = { "call_close", desc = "Close the branch" },
          ["L"] = { "call_open_all", desc = "Open three levels below" },
          ["gd"] = { "call_definition", desc = "Go to the function's definition" },
          ["t"] = { "call_turn", desc = "Switch callers and callees" },
        },
      },
    },
  })
  -- A click on ▸ or ▾ opens or closes the branch, as in the file tree; a click
  -- elsewhere on the row only moves the cursor, and a double click goes to the
  -- call, as Enter does. The click goes through first, so that the row it
  -- lands on is the current one.
  local list = panel.picker.list.win
  vim.keymap.set("n", "<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid == list.win then
      local line = vim.api.nvim_buf_get_lines(list.buf, mouse.line - 1, mouse.line, false)[1] or ""
      if M.on_mark(line, mouse.column) then
        vim.schedule(function()
          local item = is_open() and panel.picker:current()
          if item then
            toggle(item.node)
          end
        end)
      end
    end
    return "<LeftMouse>"
  end, { buffer = list.buf, expr = true, desc = "Open or close the branch clicked" })
  M.expand(top)
end

-- The tree of the function under or around the cursor, from the first source
-- that can answer for the buffer. When none can, the last one says why: it is
-- the one tried after all the others, the language server's after GTAGS'.
function M.start(direction)
  local buf = vim.api.nvim_get_current_buf()
  local last_reason
  for _, name in ipairs(M.sources) do
    local session, why = require(name).attach(buf)
    if session then
      session:start(direction, function(top, reason)
        if top then
          open_tree(session, direction, top)
        else
          vim.notify(reason, vim.log.levels.WARN)
        end
      end)
      return
    end
    last_reason = why or last_reason
  end
  vim.notify(last_reason or "No source of call trees for this buffer", vim.log.levels.WARN)
end

-- For the checks: the rows of the panel as text, guides and marks included.
function M.lines()
  if not is_open() then
    return {}
  end
  local look, out = tree_look(), {}
  for _, row in ipairs(rows()) do
    local parts = {}
    for _, part in ipairs(row_text(row, look)) do
      if part[1] then
        parts[#parts + 1] = part[1]
      elseif part.virt_text then
        parts[#parts + 1] = "  @" .. part.virt_text[2][1]
      end
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

function M.close()
  if is_open() then
    panel.picker:close()
  end
end

return M

-- Call trees from a language server's call hierarchy, for the panel in
-- lua/taka/call_tree/init.lua: the source for a file no GTAGS covers, as in Go,
-- Lua or Python, where the server attached to it answers
-- textDocument/prepareCallHierarchy. The server knows what calls what, so a
-- node is the item it hands back, asked again for its callers or callees.
local M = {}

local PREPARE = "textDocument/prepareCallHierarchy"

-- The SymbolKinds of a function, a method and a constructor.
local FUNCTION = { [6] = true, [9] = true, [12] = true }

-- A node of the tree from a call hierarchy item.
local function node_of(item, sites)
  local range = item.selectionRange or item.range
  return {
    name = item.name,
    kind = FUNCTION[item.kind] and "function" or "file",
    file = vim.uri_to_fname(item.uri),
    lnum = range.start.line + 1,
    sites = sites,
    item = item,
  }
end

-- The place of the name of the function around the cursor, where treesitter
-- can tell: the nearest node whose type says function or method and which has
-- a name. The server is asked there when the cursor is on no function's name.
local function enclosing_name(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  local node = parser:parse()[1]:root():named_descendant_for_range(row, col, row, col)
  while node do
    local kind = node:type()
    if (kind:find("function") or kind:find("method")) and not kind:find("call") then
      local name = node:field("name")[1]
      if name then
        local r, c = name:start()
        return r, c
      end
    end
    node = node:parent()
  end
end

function M.attach(buf)
  local client = vim.lsp.get_clients({ bufnr = buf, method = PREPARE })[1]
  if not client then
    return nil, "No GTAGS and no language server with call hierarchy for this file"
  end
  local session = { unknown = "not known to the language server" }

  local function request(method, params, done)
    if client:is_stopped() then
      return done(nil)
    end
    client:request(method, params, function(err, result)
      done(not err and result or nil)
    end, buf)
  end

  -- The function the word under the cursor names, else the one around it.
  function session.start(_, _, done)
    local win = vim.api.nvim_get_current_win()
    local function prepare(params, otherwise)
      request(PREPARE, params, function(items)
        if items and items[1] then
          done(node_of(items[1], nil))
        else
          otherwise()
        end
      end)
    end
    prepare(vim.lsp.util.make_position_params(win, client.offset_encoding), function()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local row, col = enclosing_name(buf, cursor[1] - 1, cursor[2])
      if not row then
        return done(nil, "No function under or around the cursor")
      end
      local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
      params.position = { line = row, character = col }
      prepare(params, function()
        done(nil, "No function under or around the cursor")
      end)
    end)
  end

  -- Callers come with the calls in their own file, callees with the calls in
  -- the node's file: the sites are where the call that links them is.
  function session.children(_, node, direction, done)
    local incoming = direction == "callers"
    local method = incoming and "callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls"
    request(method, { item = node.item }, function(calls)
      local nodes = {}
      for _, call in ipairs(calls or {}) do
        local item = incoming and call.from or call.to
        local in_file = vim.uri_to_fname((incoming and call.from or node.item).uri)
        local sites = {}
        for _, range in ipairs(call.fromRanges or {}) do
          sites[#sites + 1] = { file = in_file, lnum = range.start.line + 1 }
        end
        nodes[#nodes + 1] = node_of(item, sites)
      end
      done(nodes)
    end)
  end

  function session.branches(_, node)
    return node.item ~= nil
  end

  return session
end

return M

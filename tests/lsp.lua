-- A file no GTAGS covers, with a language server attached, as Go or Lua with
-- gopls or lua_ls: the gtags keys ask the server instead.
return function(T)
  local check, expect, temp_dir, write, key, floats, press, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.key, T.floats, T.press, T.reset_editor

  -- A server in this process that answers definitions, references and the call
  -- hierarchy for `file` from fixed places: main on line 5 calls helper on
  -- line 20 from line 7, and is called by caller on line 12 from line 14.
  local function start_server(file, buf)
    local uri = vim.uri_from_fname(file)
    local function at(line)
      return { start = { line = line - 1, character = 5 }, ["end"] = { line = line - 1, character = 9 } }
    end
    local function item(name, line)
      return { name = name, kind = 12, uri = uri, range = at(line), selectionRange = at(line) }
    end
    local answers = {
      ["textDocument/definition"] = { uri = uri, range = at(20) },
      ["textDocument/references"] = { { uri = uri, range = at(7) }, { uri = uri, range = at(20) } },
      ["textDocument/prepareCallHierarchy"] = { item("main", 5) },
      ["callHierarchy/incomingCalls"] = { { from = item("caller", 12), fromRanges = { at(14) } } },
      ["callHierarchy/outgoingCalls"] = { { to = item("helper", 20), fromRanges = { at(7) } } },
    }
    local closing = false
    return vim.lsp.start({
      name = "answers",
      root_dir = vim.fs.dirname(file),
      cmd = function(dispatchers)
        return {
          request = function(method, params, callback)
            if method == "initialize" then
              callback(nil, {
                capabilities = { definitionProvider = true, referencesProvider = true, callHierarchyProvider = true },
              })
            elseif method == "callHierarchy/outgoingCalls" or method == "callHierarchy/incomingCalls" then
              -- Only main has calls either way.
              callback(nil, params.item.name == "main" and answers[method] or {})
            elseif callback then
              callback(nil, answers[method])
            end
            return true, 1
          end,
          notify = function()
            return true
          end,
          is_closing = function()
            return closing
          end,
          terminate = function()
            closing = true
            dispatchers.on_exit(0, 15)
          end,
        }
      end,
    }, { bufnr = buf })
  end

  check("lsp: with no GTAGS, the jump, the peek and the call tree ask the language server", function()
    local dir = temp_dir()
    local lines = {}
    for i = 1, 30 do
      lines[i] = ("line %d"):format(i)
    end
    lines[5], lines[7], lines[12], lines[20] = "func main() {", "    helper()", "func caller() {", "func helper() {"
    write(dir .. "/main.go", lines)
    -- A folder named gtags beside it, as lua/taka/gtags/ is: where names are
    -- compared without case it was taken for a GTAGS, and the keys asked a
    -- GTAGS that is not there instead of the server.
    vim.fn.mkdir(dir .. "/gtags", "p")
    vim.cmd.edit(dir .. "/main.go")
    local buf = vim.api.nvim_get_current_buf()
    local id = start_server(dir .. "/main.go", buf)
    vim.wait(5000, function()
      return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/definition" }) > 0
    end, 20)
    local seen = {}
    local notify = vim.notify
    local ok, err = pcall(function()
      -- <C-]> on the call lands on the definition, by way of the tag stack.
      vim.api.nvim_win_set_cursor(0, { 7, 5 })
      key("<C-]>")()
      vim.wait(5000, function()
        return vim.fn.line(".") == 20
      end, 20)
      seen.jumped = vim.fn.line(".") .. ":" .. (vim.fn.col(".") - 1)
      seen.stack = #vim.fn.gettagstack().items
      vim.cmd("pop")
      seen.back = vim.fn.line(".")

      -- <leader>jp opens the definition in the peek window.
      key("<leader>jp")()
      vim.wait(5000, function()
        return #floats() > 0
      end, 20)
      local peek = floats()[1]
      seen.peek = peek and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(peek), 0, -1, false), " / ")
      press("<Esc>")
      vim.wait(1000, function()
        return #floats() == 0
      end, 20)

      -- The call tree both ways, from the server's call hierarchy.
      local tree = require("taka.call_tree")
      for _, direction in ipairs({ "callers", "callees" }) do
        vim.api.nvim_win_set_cursor(0, { 5, 6 })
        tree.start(direction)
        vim.wait(5000, function()
          return #tree.lines() > 1
        end, 20)
        seen[direction] = table.concat(
          vim.tbl_map(function(row)
            return vim.trim((row:gsub("%s+@", " @")))
          end, tree.lines()),
          " | "
        )
        tree.close()
        vim.wait(1000, function()
          return #tree.lines() == 0
        end, 20)
      end

      -- The writes list reads C only, and says so.
      vim.notify = function(message)
        seen.writes = message
      end
      require("taka.writes").show()
    end)
    vim.notify = notify
    vim.lsp.stop_client(id, true)
    vim.cmd("bwipeout!")
    reset_editor()
    expect(ok, tostring(err))
    expect(
      seen.jumped == "20:5" and seen.stack == 1,
      ("<C-]> landed on %s, %s on the tag stack"):format(tostring(seen.jumped), tostring(seen.stack))
    )
    expect(seen.back == 7, "after :pop the cursor is on line " .. tostring(seen.back))
    expect(seen.peek and seen.peek:find("func helper", 1, true), "the peek shows: " .. tostring(seen.peek))
    expect(
      seen.callers and seen.callers:find("main", 1, true) and seen.callers:find("caller", 1, true),
      "callers: " .. tostring(seen.callers)
    )
    expect(
      seen.callees and seen.callees:find("main", 1, true) and seen.callees:find("helper", 1, true),
      "callees: " .. tostring(seen.callees)
    )
    expect(tostring(seen.writes):find("C only", 1, true), "the writes list said: " .. tostring(seen.writes))
  end)
end

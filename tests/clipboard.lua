-- The clipboard over ssh (lua/config/clipboard.lua).
return function(T)
  local check, expect, temp_dir, write = T.check, T.expect, T.temp_dir, T.write

  -- Over ssh a yank goes to the terminal at hand as OSC 52, and p puts what
  -- was last yanked: an nvim of this config started as an ssh session takes
  -- the provider, yanks and puts without coming back to the provider without
  -- end, and one started outside ssh keeps the Windows clipboard.
  check("clipboard: over ssh a yank goes to the terminal at hand, and p puts it", function()
    local clipboard = require("config.clipboard")
    local sent = {}
    local provider = clipboard.provider(function(register)
      return function(lines)
        sent[#sent + 1] = register .. ":" .. table.concat(lines, "|")
      end
    end)
    provider.copy["+"]({ "first", "second" }, "V")
    local held = provider.paste["+"]()
    expect(table.concat(sent, " ") == "+:first|second", "sent: " .. table.concat(sent, " "))
    expect(table.concat(held[1], "|") == "first|second" and held[2] == "V", "put back: " .. vim.inspect(held))
    local function started(env)
      local script = temp_dir() .. "/yank.lua"
      write(script, {
        "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'yanked line' })",
        "vim.cmd('normal! yyp')",
        "io.stdout:write((vim.g.clipboard and vim.g.clipboard.name or 'none') .. '|' .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '/'))",
        "vim.cmd('qa!')",
      })
      local result = vim
        .system({ "nvim", "--headless", "-n", "-c", "luafile " .. script }, { env = env, text = true })
        :wait(30000)
      return vim.trim(result.stdout or "")
    end
    local over_ssh = started({ SSH_CONNECTION = "192.0.2.1 50000 192.0.2.2 22" })
    expect(over_ssh == "OSC 52 to the terminal at hand|yanked line/yanked line", "over ssh: " .. over_ssh)
    local outside = started({ SSH_CONNECTION = "", SSH_CLIENT = "", SSH_TTY = "" })
    expect(outside:match("^none|"), "outside ssh: " .. outside)
  end)
end

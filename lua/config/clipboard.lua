-- The clipboard over ssh. There the OS clipboard is the one of the machine
-- logged into, so a yank went into a clipboard no one in front of a screen
-- reads, and Ctrl+V at hand pasted something else. A yank is handed instead to
-- the terminal at hand as an OSC 52 sequence, which puts it on that machine's
-- clipboard; WezTerm does so as it comes, and the sequence gets through the
-- console of a Windows ssh server (tried: what nvim sent over ssh was pasted at
-- hand).
--
-- The other way, reading the terminal's clipboard with an escape, most
-- terminals refuse, and Neovim's own reader then waits ten seconds at every p.
-- So p puts what was last yanked in this nvim, and text copied at hand comes
-- in with the terminal's own paste (Ctrl+Shift+V in WezTerm).
local M = {}

function M.over_ssh()
  return (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY) ~= nil
end

-- A provider for vim.g.clipboard, with `send` writing the sequence (Neovim's
-- OSC 52 writer when not given). What was last yanked is kept here: with
-- clipboard=unnamedplus the unnamed register is the clipboard, and reading it
-- from the paste would come back to this provider without end.
function M.provider(send)
  send = send or function(register)
    return require("vim.ui.clipboard.osc52").copy(register)
  end
  local held = { {}, "v" }
  local function copy(register)
    local write = send(register)
    return function(lines, regtype)
      held = { vim.deepcopy(lines), regtype }
      write(lines, regtype)
    end
  end
  local function paste()
    return held
  end
  return {
    name = "OSC 52 to the terminal at hand",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste, ["*"] = paste },
  }
end

return M

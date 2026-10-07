-- The Japanese input method turned off on leaving Insert mode or the command
-- line, on Windows. Left on in Normal mode it takes the keys before Neovim
-- does: Space came in as a full-width space, mapped to nothing, so <leader>
-- and every picker on it did nothing, and the keys after it went into the
-- input method's composition.
--
-- The input method of the window in front is told to close, as zenhan.exe
-- does, through the Windows API from LuaJIT: no tool to install, and no
-- process started on every Esc. It is left off on entering Insert mode again;
-- turned back on by itself, it would make text Japanese without being asked.
-- Nothing is sent while the editor's window does not have the focus, nor with
-- no screen attached, as in the checks: the window in front is then another
-- program's.
local M = {}

local WM_IME_CONTROL = 0x0283
local IMC_SETOPENSTATUS = 0x0006
local SMTO_ABORTIFHUNG = 0x0002

local api
-- The functions of user32 and imm32, or false where they cannot be had.
local function windows()
  if api ~= nil then
    return api
  end
  api = false
  if vim.fn.has("win32") == 0 then
    return api
  end
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return api
  end
  pcall(
    ffi.cdef,
    [[
      void *GetForegroundWindow(void);
      void *ImmGetDefaultIMEWnd(void *window);
      intptr_t SendMessageTimeoutW(void *window, unsigned int message, uintptr_t wparam,
        intptr_t lparam, unsigned int flags, unsigned int timeout, uintptr_t *result);
    ]]
  )
  local loaded, user32, imm32 = pcall(function()
    return ffi.load("user32"), ffi.load("imm32")
  end)
  if loaded then
    api = { ffi = ffi, user32 = user32, imm32 = imm32 }
  end
  return api
end

local focused = true

-- Whether the input method can be turned off here.
function M.available()
  return windows() ~= false
end

-- Turns the input method of the window in front off. A window that does not
-- answer within 50 ms is given up on, so a hung program never holds the editor.
function M.off()
  local win = windows()
  if not win or not focused or #vim.api.nvim_list_uis() == 0 then
    return
  end
  local front = win.user32.GetForegroundWindow()
  if front == nil then
    return
  end
  local ime = win.imm32.ImmGetDefaultIMEWnd(front)
  if ime == nil then
    return
  end
  local result = win.ffi.new("uintptr_t[1]")
  win.user32.SendMessageTimeoutW(ime, WM_IME_CONTROL, IMC_SETOPENSTATUS, 0, SMTO_ABORTIFHUNG, 50, result)
end

local group = vim.api.nvim_create_augroup("taka_ime", { clear = true })
vim.api.nvim_create_autocmd({ "InsertLeave", "CmdlineLeave" }, {
  group = group,
  callback = function()
    M.off()
  end,
})
vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
  group = group,
  callback = function(args)
    focused = args.event == "FocusGained"
  end,
})

return M

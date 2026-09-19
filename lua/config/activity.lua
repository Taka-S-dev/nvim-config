-- What is running in the background, for the statusline.
--
-- A lookup, an index build and a ctags run all take an unknown time and draw
-- nothing of their own, so a key press that started one looks the same as a key
-- press that was lost. Each of them registers here: while it runs the
-- statusline shows a spinner, its label and, past the first second, how long it
-- has been going; when it ends, what it took and how it went, for two seconds.
--
-- The jobs are kept as a list rather than as one current text. A definition
-- jump made while an index is building would otherwise take the statusline
-- over, and the build would go on with nothing left to say so.
--
-- lua/plugins/lualine-activity.lua draws vim.g.background_activity.
local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame = 1
local active = {} ---@type { label: string, started: integer }[] newest last
local result ---@type { text: string, expires: integer }|nil
local timer

local function redraw()
  local ok, lualine = pcall(require, "lualine")
  if ok then
    lualine.refresh({ place = { "statusline" } })
  else
    vim.cmd.redrawstatus()
  end
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function render()
  local now = vim.uv.hrtime()
  local text
  if result and now < result.expires then
    text = result.text
  else
    result = nil
    local job = active[#active]
    if job then
      local seconds = math.floor((now - job.started) / 1e9)
      text = ("%s %s"):format(frames[frame], job.label)
      if seconds >= 1 then
        text = ("%s  %d s"):format(text, seconds)
      end
      if #active > 1 then
        text = ("%s  (+%d)"):format(text, #active - 1)
      end
    end
  end
  if vim.g.background_activity ~= text then
    vim.g.background_activity = text
    redraw()
  end
  if not text then
    stop_timer()
  end
end

local function start_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      frame = frame % #frames + 1
      render()
    end)
  )
end

---Register something that has started. The returned function reports how it
---ended and returns the milliseconds it took; calling it twice does nothing.
---@param label string
---@return fun(outcome: string): number
function M.begin(label)
  local job = { label = label, started = vim.uv.hrtime() }
  active[#active + 1] = job
  render()
  start_timer()
  return function(outcome)
    local took = (vim.uv.hrtime() - job.started) / 1e6
    for i, other in ipairs(active) do
      if other == job then
        table.remove(active, i)
        local shown = took < 10000 and ("%.0f ms"):format(took) or ("%.0f s"):format(took / 1000)
        result = { text = ("%s  %s (%s)"):format(label, shown, outcome), expires = vim.uv.hrtime() + 2e9 }
        render()
        start_timer()
        break
      end
    end
    return took
  end
end

return M

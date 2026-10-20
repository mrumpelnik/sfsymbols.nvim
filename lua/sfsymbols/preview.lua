local M = {}
local renderer = require("sfsymbols.renderer")
local images = require("sfsymbols.preview_image")
local states = setmetatable({}, { __mode = "k" })
local namespace = vim.api.nvim_create_namespace("sfsymbols.preview")
vim.api.nvim_set_hl(0, "SFSymbolsPreviewHeading", { default = true, bold = true })
vim.api.nvim_set_hl(0, "SFSymbolsPreviewDivider", { default = true, link = "NonText" })

local function foreground(ctx)
  local group = "Normal"
  local win = ctx.preview.win and ctx.preview.win.win
  if win and vim.api.nvim_win_is_valid(win) then
    local source = win == vim.api.nvim_get_current_win() and "Normal" or "NormalNC"
    group = source
    for mapping in vim.wo[win].winhighlight:gmatch("[^,]+") do
      local from, to = mapping:match("^([^:]+):([^:]+)$")
      if from == source then
        group = to
      end
    end
  end
  local color = vim.api.nvim_get_hl(0, { name = group, link = false, create = false }).fg
  if color == nil and group ~= "Normal" then
    color = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg
  end
  return type(color) == "number" and string.format("%06x", color % 0x1000000) or "8c8c8c"
end

local function wrap_entries(entries, width)
  local lines, line = {}, ""
  for _, entry in ipairs(entries) do
    if vim.api.nvim_strwidth(entry) > width then
      if line ~= "" then
        lines[#lines + 1] = line
      end
      line = ""
      for word in entry:gmatch("%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and vim.api.nvim_strwidth(candidate) > width then
          lines[#lines + 1] = line
          line = "  " .. word
        else
          line = candidate
        end
      end
    else
      local separator = line == "" and "" or " · "
      if line ~= "" and vim.api.nvim_strwidth(line .. separator .. entry) > width then
        lines[#lines + 1] = line
        line = entry
      else
        line = line .. separator .. entry
      end
    end
  end
  lines[#lines + 1] = line
  return lines
end

local function details(item, width, message)
  local availability = type(item.availability) == "table" and item.availability or {}
  local versions = availability.monochrome
  if type(versions) ~= "table" or next(versions) == nil then
    versions = availability["Name availability"]
  end
  local entries = {}
  for _, platform in ipairs({ "iOS", "macOS", "Mac Catalyst", "tvOS", "watchOS", "visionOS" }) do
    if type(versions) == "table" and versions[platform] then
      entries[#entries + 1] = platform .. " " .. tostring(versions[platform])
    end
  end
  if #entries == 0 then
    entries = { type(versions) == "table" and "No platform versions listed" or "No base availability listed" }
  end
  local modes = {}
  for _, mode in ipairs({ "monochrome", "hierarchical", "palette", "multicolor" }) do
    if type(availability[mode]) == "table" then
      modes[#modes + 1] = mode:sub(1, 1):upper() .. mode:sub(2)
    end
  end
  if #modes == 0 then
    modes = { "Not provided" }
  end
  local lines =
    { item.name, "", message or "", string.rep("─", math.max(1, math.min(40, width - 2))), "Availability" }
  local summary_width = math.max(12, width - 4)
  vim.list_extend(lines, wrap_entries(entries, summary_width))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Rendering modes"
  vim.list_extend(lines, wrap_entries(modes, summary_width))
  return lines
end

local function dimensions(ctx)
  local win = ctx.preview.win and ctx.preview.win.win
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  end
  return 80, 24
end

local function image_bounds(ctx, item)
  local width, height = dimensions(ctx)
  local lines = details(item, width)
  local max_width, max_height = math.min(32, width - 4), math.min(12, height - #lines + 1)
  if max_width < 20 or vim.api.nvim_strwidth(item.name) > width - 4 or max_height < 4 then
    return nil
  end
  return { width = max_width, height = max_height }, lines
end

local function show_text(ctx, lines)
  ctx.preview:reset()
  ctx.preview:minimal()
  ctx.preview:set_title("Preview")
  ctx.preview:set_lines(lines)
  local buf = ctx.preview.win and ctx.preview.win.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for row, line in ipairs(lines) do
      local group
      if row == 1 or line == "Availability" or line == "Rendering modes" then
        group = "SFSymbolsPreviewHeading"
      elseif row == 4 then
        group = "SFSymbolsPreviewDivider"
      elseif row == 3 and vim.trim(line) ~= "" then
        group = "NonText"
      end
      if group then
        vim.api.nvim_buf_add_highlight(buf, namespace, group, row - 1, 0, -1)
      end
    end
  end
  local win = ctx.preview.win and ctx.preview.win.win
  if win and vim.api.nvim_win_is_valid(win) then
    local fields = {}
    for field in vim.wo[win].fillchars:gmatch("[^,]+") do
      if not field:match("^eob:") then
        fields[#fields + 1] = field
      end
    end
    fields[#fields + 1] = "eob:" .. vim.fn.nr2char(160)
    pcall(vim.api.nvim_set_option_value, "fillchars", table.concat(fields, ","), { scope = "local", win = win })
  end
end

local function stop_timer(state)
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

local function cancel_job(state)
  if state.job then
    state.job.cancel()
    state.job = nil
  end
end

local function clear_image(state)
  if state.image then
    state.image:cleanup()
    state.image = nil
  end
  if state.image_path then
    state.renderer:remove(state.image_path)
    state.image_path = nil
  end
end

function M.cleanup(picker)
  local state = states[picker]
  if state then
    state.generation = state.generation + 1
    stop_timer(state)
    cancel_job(state)
    clear_image(state)
    state.renderer:cleanup()
    states[picker] = nil
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("sfsymbols.preview", { clear = true }),
  callback = function()
    for key in pairs(states) do
      M.cleanup(key)
    end
  end,
})

local function is_current(state, ctx, generation)
  if state.generation ~= generation or (ctx.picker and ctx.picker.closed) then
    return false
  end
  if ctx.picker and ctx.picker.current then
    local ok, current = pcall(ctx.picker.current, ctx.picker, { resolve = false })
    if ok and (not current or current.name ~= ctx.item.name) then
      return false
    end
  end
  return true
end

local function show_error(state, ctx, message)
  clear_image(state)
  show_text(ctx, details(ctx.item, dimensions(ctx), message))
end

local function render_image(state, snacks, ctx, generation)
  local completed = false
  local ok, job = pcall(state.renderer.render, state.renderer, ctx.item.name, function(path, err)
    completed = true
    if not is_current(state, ctx, generation) then
      if path then
        state.renderer:remove(path)
      end
      return
    end
    state.job = nil
    if not path then
      show_error(state, ctx, err and err.message or "Could not render native SF Symbol")
      return
    end
    state.image_path = path
    local attached, attach_error = pcall(function()
      -- Recheck the dimensions after rendering: the user may have resized.
      local bounds, lines = image_bounds(ctx, ctx.item)
      if not bounds then
        show_error(state, ctx, "Preview is too small for the symbol image")
        return
      end
      local size = snacks.image.util.fit(path, bounds)
      local width = dimensions(ctx)
      local column = math.max(0, math.floor((width - size.width) / 2))
      lines[3] = string.rep(" ", column)
      show_text(ctx, lines)
      state.image = images.attach(snacks, ctx.preview.win.buf, {
        src = path,
        pos = { 3, column },
        inline = true,
        width = bounds.width,
        height = bounds.height,
      })
    end)
    if not attached then
      show_error(state, ctx, "Could not show SF Symbol PNG: " .. tostring(attach_error))
    end
  end, foreground(ctx))
  if not ok then
    if is_current(state, ctx, generation) then
      show_error(state, ctx, "Could not render native SF Symbol: " .. tostring(job))
    end
  elseif not completed then
    state.job = job
  end
end

local function prepare_image(state, snacks, ctx, generation)
  if snacks.image.config.enabled == false then
    show_error(state, ctx, "Snacks image previews are disabled")
    return
  end
  if not snacks.image.supports_file("symbol.png") then
    show_error(state, ctx, "Snacks does not support PNG previews")
    return
  end
  if not image_bounds(ctx, ctx.item) then
    show_error(state, ctx, "Preview is too small for the symbol image")
    return
  end
  local detected, detect_error = pcall(snacks.image.terminal.detect, function()
    if not is_current(state, ctx, generation) then
      return
    end
    local ok, supported = pcall(snacks.image.supports_terminal)
    if not ok or not supported then
      show_error(state, ctx, ok and "Terminal does not support Kitty Graphics Protocol" or tostring(supported))
      return
    end
    render_image(state, snacks, ctx, generation)
  end)
  if not detected then
    show_error(state, ctx, "Could not detect terminal image support: " .. tostring(detect_error))
  end
end

function M.show(snacks, ctx)
  local key = ctx.picker or ctx.preview
  local state = states[key]
  if not state then
    state = { generation = 0, renderer = renderer.new_session() }
    states[key] = state
  end
  state.generation = state.generation + 1
  local generation = state.generation
  stop_timer(state)
  cancel_job(state)
  clear_image(state)
  show_text(ctx, details(ctx.item, dimensions(ctx), "Rendering native SF Symbol..."))
  state.timer = (vim.uv or vim.loop).new_timer()
  state.timer:start(
    100,
    0,
    vim.schedule_wrap(function()
      -- A stale scheduled callback must not stop a replacement selection's timer.
      if not is_current(state, ctx, generation) then
        return
      end
      stop_timer(state)
      prepare_image(state, snacks, ctx, generation)
    end)
  )
end

return M

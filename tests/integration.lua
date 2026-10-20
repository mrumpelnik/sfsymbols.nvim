vim.opt.rtp:prepend(vim.fn.getcwd())
local snacks_path = vim.env.SNACKS_PATH or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
assert(vim.fn.isdirectory(snacks_path) == 1, "Set SNACKS_PATH to your Snacks checkout")
vim.opt.rtp:prepend(snacks_path)
-- Use an empty owned cache so integration actually compiles the current helper.
local stdpath = vim.fn.stdpath
local test_cache = assert(vim.uv.fs_mkdtemp(stdpath("cache") .. "/sfsymbols-integration-XXXXXX"))
vim.fn.stdpath = function(kind)
  return kind == "cache" and test_cache or stdpath(kind)
end
require("snacks").setup({ picker = { enabled = true, ui_select = false }, image = { enabled = true } })
local cli = "/Applications/SF Symbols.app/Contents/Executables/sfsymbols"
local done, records, failure = false, nil, nil
require("sfsymbols.catalog").load(cli, function(items, err)
  records, failure, done = items, err, true
end)
assert(
  vim.wait(20000, function()
    return done
  end),
  "Catalog timed out"
)
assert(records, failure)
assert(#records > 1000, "Expected the full symbol catalog")
local map = vim.iter(records):find(function(item)
  return item.name == "map.fill"
end)
assert(map and map.glyph ~= "" and map.availability.monochrome.iOS)
local localized = vim.iter(records):find(function(item)
  return item.name == "character.magnify.kn"
end)
assert(localized and localized.availability["Name availability"].iOS == "18.4")
for _, name in ipairs({ "character.magnify.ar", "character.magnify.ja", "character.magnify.ko" }) do
  assert(
    vim.iter(records):find(function(item)
      return item.name == name
    end),
    "Missing " .. name
  )
end
local plugin = require("sfsymbols")
plugin.setup()
plugin.open({ query = "map" })
assert(
  vim.wait(5000, function()
    return #Snacks.picker.get() > 0
  end),
  "Picker did not open"
)
local picker = Snacks.picker.get()[1]
assert(
  vim.wait(5000, function()
    return not picker:is_active() and picker:current() ~= nil
  end),
  "No picker results"
)
local map_index
assert(
  vim.wait(5000, function()
    for index = 1, picker.list:count() do
      local item = picker.list:get(index)
      if item and item.name == "map.fill" then
        map_index = index
        return true
      end
    end
  end),
  "Map results did not include map.fill"
)
picker.list:move(map_index, true)
assert(picker:current().name == "map.fill", vim.inspect(picker:current()))
local function find_preview_layout(box)
  if type(box) ~= "table" then
    return nil
  end
  if box.win == "preview" then
    return box
  end
  for _, child in ipairs(box) do
    local found = find_preview_layout(child)
    if found then
      return found
    end
  end
end
assert(
  find_preview_layout(picker.resolved_layout.layout).width == 0.6,
  "Preview should occupy 60% of the picker layout"
)
local list_namespace = vim.api.nvim_get_namespaces()["snacks.picker.list"]
local list_marks = vim.api.nvim_buf_get_extmarks(picker.list.win.buf, list_namespace, 0, -1, { details = true })
assert(not vim.iter(list_marks):any(function(mark)
  return mark[4].virt_lines ~= nil
end), "Picker rows should not have blank spacer lines")
if picker.list:count() > 1 then
  local current_name = picker:current().name
  picker.list:move(1)
  assert(picker:current().name ~= current_name, "List navigation should advance one symbol")
  picker.list:move(-1)
  assert(picker:current().name == current_name, "List navigation should return to the original symbol")
end
for _, window in ipairs({ picker.opts.win.input, picker.opts.win.list }) do
  local keys = window.keys
  assert(keys[Snacks.util.normkey("<C-a>")] == false, "Ctrl-A should not select all")
  assert(keys[Snacks.util.normkey("<S-Tab>")] == false, "Shift-Tab should not multi-select")
  local tab = keys[Snacks.util.normkey("<Tab>")]
  assert(tab == false or tab[1] == "sfsymbols_insert", "Tab should not multi-select")
end
-- Render a native PNG to a per-session cache and verify its cleanup.
local renderer = require("sfsymbols.renderer")
local cache_directory = vim.fs.joinpath(vim.fn.stdpath("cache"), "sfsymbols.nvim")
local png_session = renderer.new_session()
local native_png
png_session:render("map.circle.fill", function(path, err)
  native_png = { path = path, error = err }
end, "4f738a")
assert(
  vim.wait(150000, function()
    return native_png ~= nil
  end),
  "Native PNG rendering timed out"
)
assert(native_png.path, vim.inspect(native_png.error))
local png = native_png.path
local png_directory = vim.fs.dirname(png)
assert(png_directory ~= cache_directory, "Preview PNGs should live in a session directory")
local fd = assert(vim.uv.fs_open(png, "r", 438))
local signature = assert(vim.uv.fs_read(fd, 8, 0))
vim.uv.fs_close(fd)
assert(signature == "\137PNG\r\n\26\n", "Renderer did not produce a PNG")
local pixel_check
vim.system(
  { "swift", vim.fs.joinpath(vim.fn.getcwd(), "tests/check_render.swift"), png, "4f738a" },
  { text = true, timeout = 60000 },
  function(result)
    pixel_check = result
  end
)
assert(
  vim.wait(60000, function()
    return pixel_check ~= nil
  end),
  "Rendered PNG color check timed out"
)
assert(pixel_check.code == 0, pixel_check.stderr)

-- Exercise real Snacks identification even in headless terminals. Only the
-- terminal transport and buffer display are stubbed, not its conversion/cache.
local transport, attach = Snacks.image.terminal.request, Snacks.image.buf.attach
Snacks.image.terminal.request = function() end
Snacks.image.buf.attach = function() end
local transient = require("sfsymbols.preview_image").attach(Snacks, vim.api.nvim_create_buf(false, true), { src = png })
local image = Snacks.image.image.new(png)
assert(
  vim.wait(10000, function()
    return image._convert:done()
  end),
  "PNG identification timed out"
)
assert(not image._convert:error(), tostring(image._convert:error()))
local identify = image._convert.steps[#image._convert.steps]
assert(identify.name == "identify" and vim.uv.fs_stat(identify.file), "Expected Snacks metadata output")
transient:cleanup()
assert(not vim.uv.fs_stat(identify.file), "Snacks metadata leaked after preview cleanup")
Snacks.image.terminal.request, Snacks.image.buf.attach = transport, attach
png_session:cleanup()
assert(not vim.uv.fs_stat(png), "Session cleanup should remove its temporary PNG")
assert(not vim.uv.fs_stat(png_directory), "Session cleanup should remove its temporary directory")

-- The picker keeps availability visible if image support is unavailable.
local attached_path
local attached_opts
local attached_buffer
local attached_lines
local attach_image = Snacks.image.buf.attach
Snacks.image.buf.attach = function(buf, opts)
  attached_path = opts.src
  attached_opts = opts
  attached_buffer = buf
  attached_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return attach_image(buf, opts)
end
local preview_window = picker.preview.win.win
vim.wo[preview_window].number = true
vim.wo[preview_window].relativenumber = true
vim.wo[preview_window].signcolumn = "yes"
picker.opts.preview({ item = map, preview = picker.preview, picker = picker })
local function assert_minimal_preview()
  assert(not vim.wo[preview_window].number, "Preview should hide line numbers after reset")
  assert(not vim.wo[preview_window].relativenumber, "Preview should hide relative line numbers")
  assert(vim.wo[preview_window].signcolumn == "no", "Preview should hide the sign column")
end
assert_minimal_preview()
local function map_preview_complete()
  if attached_path then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  return lines[3] ~= "Rendering native SF Symbol..." and text:find("iOS 13.0", 1, true) ~= nil
end
local function map_availability_visible()
  local lines = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false)
  return table.concat(lines, "\n"):find("iOS 13.0", 1, true) ~= nil
end
assert(vim.wait(30000, map_preview_complete), "Map preview did not render or show platform availability")
assert_minimal_preview()
Snacks.image.buf.attach = attach_image
if attached_path then
  assert(vim.fn.filereadable(attached_path) == 1)
end
assert(map_availability_visible(), "Map preview omitted platform availability: " .. vim.inspect({
  path = attached_path,
  buffer = attached_buffer,
  current = picker.preview.win.buf,
  before = attached_lines,
  after = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false),
}))
assert(vim.wo[picker.preview.win.win].fillchars:find("eob:" .. vim.fn.nr2char(160), 1, true))
local preview_text = table.concat(vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false), "\n")
assert(preview_text:find("Rendering modes", 1, true))
if attached_path then
  local fitted = Snacks.image.util.fit(attached_path, { width = attached_opts.width, height = attached_opts.height })
  local centered = math.floor((vim.api.nvim_win_get_width(picker.preview.win.win) - fitted.width) / 2)
  assert(
    attached_opts.pos[1] == 3 and attached_opts.pos[2] == centered,
    "Preview image should be centered below its heading"
  )
  assert(#attached_lines[3] == attached_opts.pos[2], "Centered image anchor should be valid in its buffer")
  assert(attached_opts.width <= 32 and attached_opts.height <= 12, "Preview image should remain a medium size")
end

assert(localized.glyph == "", "Expected the localized metadata-only catalog entry")
local attach_preview = Snacks.image.buf.attach
local attached_availability = false
Snacks.image.buf.attach = function(buf, opts)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  attached_availability = text:find("character.magnify.kn", 1, true) ~= nil and text:find("iOS 18.4", 1, true) ~= nil
  return attach_preview(buf, opts)
end
local localized_picker = {
  closed = false,
  current = function()
    return localized
  end,
}
picker.opts.preview({ item = localized, preview = picker.preview, picker = localized_picker })
local function localized_availability_visible()
  local lines = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  return lines[1] == "character.magnify.kn"
    and text:find("iOS 18.4", 1, true) ~= nil
    and text:find("Rendering modes\nNot provided", 1, true) ~= nil
end
local function localized_preview_complete()
  if attached_availability then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  return lines[3] ~= "Rendering native SF Symbol..." and localized_availability_visible()
end
assert(vim.wait(30000, localized_preview_complete), "Localized symbol preview omitted its platform availability")
assert(localized_availability_visible(), "Platform availability must remain visible in the preview buffer")
assert_minimal_preview()
Snacks.image.buf.attach = attach_preview
picker.opts.on_close(localized_picker)
local unavailable_session = renderer.new_session()
local unavailable
unavailable_session:render("sfsymbols.nvim.definitely-unavailable", function(path, err)
  unavailable = { path = path, error = err }
end)
assert(
  vim.wait(30000, function()
    return unavailable ~= nil
  end),
  "Missing symbol availability check timed out"
)
assert(not unavailable.path and unavailable.error.kind == "unavailable")
unavailable_session:cleanup()
local main = picker.main
vim.api.nvim_win_call(main, function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { '""' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end)
picker.opts.actions.sfsymbols_insert(picker, map)
assert(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(main), 0, 1, false)[1] == '"map.fill"')
if attached_path then
  assert(not vim.uv.fs_stat(attached_path), "Picker close should remove its temporary preview PNG")
  assert(not vim.uv.fs_stat(vim.fs.dirname(attached_path)), "Picker close should remove its temporary directory")
end
local exit_session = renderer.new_session()
local exit_preview
exit_session:render("map.fill", function(path, err)
  assert(path, vim.inspect(err))
  exit_preview = path
end)
assert(
  vim.wait(30000, function()
    return exit_preview ~= nil
  end),
  "Exit-cleanup preview timed out"
)
local exit_directory = vim.fs.dirname(exit_preview)
vim.api.nvim_exec_autocmds("VimLeavePre", {})
assert(not vim.uv.fs_stat(exit_preview), "VimLeavePre should remove temporary preview PNGs")
assert(not vim.uv.fs_stat(exit_directory), "VimLeavePre should remove temporary preview directories")
assert(#vim.fn.glob(cache_directory .. "/render-*", false, true) == 1, "Expected one published helper")
assert(#vim.fn.glob(cache_directory .. "/build-*", false, true) == 0, "Temporary helper output leaked")
vim.fn.stdpath = stdpath
vim.fn.delete(test_cache, "rf")
print(
  "Integration passed: "
    .. #records
    .. " symbols; compact rows, centered tinted previews, availability, cleanup, picker keys, and insertion verified"
)

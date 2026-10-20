vim.opt.rtp:prepend(vim.fn.getcwd())
local catalog = require("sfsymbols.catalog")
local fixture = vim.json.encode({
  { name = "star.fill", glyph = "STAR", availability = {} },
  {
    name = "map.fill",
    glyph = "MAP",
    availability = {
      monochrome = {
        iOS = "13.0",
        macOS = "11.0",
        ["Mac Catalyst"] = "13.0",
        tvOS = "13.0",
        watchOS = "6.0",
        visionOS = "1.0",
      },
      hierarchical = { iOS = "18.0" },
      palette = { iOS = "18.1" },
      multicolor = { iOS = "13.0" },
    },
  },
  { name = "no.glyph" },
})
local items = assert(catalog.decode(fixture))
assert(items[1].name == "map.fill")
assert(items[1].text == "map.fill")
assert(items[1].availability.hierarchical.iOS == "18.0")
assert(items[1].availability.palette.iOS == "18.1")
assert(items[2].glyph == "")
assert(not catalog.decode("not json"))
assert(not catalog.decode('{"name":"map"}'))
assert(not catalog.decode('[{"name":4}]'))
assert(#assert(catalog.decode("[]")) == 0)

local metadata = vim.json.encode({
  symbols = { ["map.fill"] = "2019", ["character.magnify.kn"] = "2024.3" },
  year_to_release = { ["2019"] = { iOS = "13.0" }, ["2024.3"] = { iOS = "18.4" } },
})
local merged = assert(catalog.merge(vim.deepcopy(items), metadata))
assert(#merged == #items + 1)
assert(merged[1].name == "character.magnify.kn" and merged[1].glyph == "")
assert(merged[1].availability["Name availability"].iOS == "18.4")
assert(merged[2].name == "map.fill" and merged[2].glyph == "MAP")
assert(not catalog.merge({}, "{}"))
assert(not catalog.merge({}, "not json"))

-- Async catalog loading: coalesce requests, cache success, retry errors.
local system = vim.system
local calls, completion = 0, nil
vim.system = function(argv, opts, callback)
  if argv[1] == "/usr/bin/plutil" then
    assert(argv[6]:find("/Resources/Metadata/name_availability.plist", 1, true))
    callback({ code = 0, stdout = metadata })
    return
  end
  calls = calls + 1
  assert(argv[3] == "" and argv[5] == "0")
  assert(opts.timeout == 15000)
  completion = callback
end
local delivered = 0
local function receive(result, err)
  assert(result and not err)
  delivered = delivered + 1
end
catalog.load("test-cli", receive)
catalog.load("test-cli", receive)
assert(calls == 1)
completion({ code = 0, stdout = fixture })
assert(vim.wait(1000, function()
  return delivered == 2
end))
catalog.load("test-cli", receive)
assert(delivered == 3 and calls == 1)
local failure
catalog.load("retry-cli", function(_, err)
  failure = err
end)
completion({ code = 1, stderr = "test failure" })
assert(vim.wait(1000, function()
  return failure ~= nil
end))
assert(failure:find("test failure", 1, true))
catalog.load("retry-cli", receive)
completion({ code = 0, stdout = fixture })
assert(vim.wait(1000, function()
  return delivered == 4
end))
vim.system = system

-- Picker options and actions, without changing the actual clipboard.
local load = catalog.load
catalog.load = function(_, callback)
  callback(items)
end
local executable = vim.fn.executable
vim.fn.executable = function()
  return 1
end
local captured
local attached
local attach_failure = false
local fake_renderer
fake_renderer = {
  requests = {},
  removed = {},
  new_session = function()
    fake_renderer.sessions = (fake_renderer.sessions or 0) + 1
    return {
      render = function(_, name, callback, foreground)
        if name == "renderer.throws" then
          error("renderer launch failed")
        end
        local request = { name = name, callback = callback, foreground = foreground }
        table.insert(fake_renderer.requests, request)
        return {
          cancel = function()
            fake_renderer.cancelled = (fake_renderer.cancelled or 0) + 1
          end,
        }
      end,
      remove = function(_, path)
        table.insert(fake_renderer.removed, path)
      end,
      cleanup = function()
        fake_renderer.cleaned = (fake_renderer.cleaned or 0) + 1
      end,
    }
  end,
}
package.loaded["sfsymbols.renderer"] = fake_renderer
package.loaded.snacks = {
  picker = {
    pick = function(opts)
      captured = opts
    end,
  },
  image = {
    config = { enabled = true },
    image = {
      new = function()
        return { on_ready = function() end }
      end,
    },
    supports_file = function()
      return true
    end,
    supports_terminal = function()
      return true
    end,
    terminal = {
      detect = function(callback)
        callback()
      end,
    },
    buf = {
      attach = function(buf, opts)
        if attach_failure then
          error("image attach failed")
        end
        attached = { buf = buf, opts = opts }
      end,
    },
    util = {
      fit = function(_, size)
        return { width = math.min(20, size.width), height = math.min(10, size.height) }
      end,
    },
    placement = {
      clean = function() end,
    },
  },
}
local plugin = require("sfsymbols")
plugin.setup()
assert(vim.fn.exists(":SFSymbols") == 2)
local original_normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
vim.api.nvim_set_hl(0, "Normal", { fg = "#123456", bg = "#654321" })
plugin.open({ query = "map" })
assert(captured.pattern == "map")
assert(captured.items[1].name == "map.fill")
assert(captured.layout.preset == "default")
local layout =
  captured.layout.config({ preset = "default", layout = { box = "horizontal", { win = "list" }, { win = "preview" } } })
assert(layout.layout[2].width == 0.6)
local icon_chunk = function(item)
  for _, chunk in ipairs(captured.format(item)) do
    if type(chunk[1]) == "string" then
      return chunk
    end
  end
end
assert(icon_chunk(items[1])[1] == "MAP " and icon_chunk(items[1])[2] == "SFSymbolsGlyph")
assert(vim.trim(icon_chunk(items[2])[1]) == "􀻃" and icon_chunk(items[2])[2] == "SFSymbolsGlyphMissing")
assert(vim.api.nvim_strwidth(icon_chunk({ name = "test", glyph = "MM" })[1]) == 3)
assert(vim.api.nvim_strwidth(icon_chunk(items[2])[1]) == 3)
for _, chunk in ipairs(captured.format(items[1])) do
  assert(not chunk.virt_lines, "List entries should not have blank spacer lines")
end
local glyph_highlight = vim.api.nvim_get_hl(0, { name = "SFSymbolsGlyph", link = false })
local missing_highlight = vim.api.nvim_get_hl(0, { name = "SFSymbolsGlyphMissing", link = false })
assert(glyph_highlight.fg == 0x123456 and (glyph_highlight.bg == nil or glyph_highlight.bg == 0))
assert(missing_highlight.bg == nil or missing_highlight.bg == 0)
assert(captured.win.input.keys["<C-a>"] == false)
assert(captured.win.input.keys["<Tab>"] == false)
assert(captured.win.input.keys["<S-Tab>"] == false)
assert(captured.win.list.keys["<C-a>"] == false)
assert(captured.win.list.keys["<Tab>"] == false)
assert(captured.win.list.keys["<S-Tab>"] == false)
assert(captured.win.input.keys["<C-i>"][1] == "sfsymbols_insert")
assert(captured.win.list.keys["<C-i>"][1] == "sfsymbols_insert")

local preview = {
  win = { win = vim.api.nvim_get_current_win() },
  minimal = function(self)
    self.number = false
    self.relativenumber = false
    self.signcolumn = "no"
  end,
  reset = function(self)
    self.number = true
    self.relativenumber = true
    self.signcolumn = "yes"
    self.lines = {}
    self.win.buf = vim.api.nvim_create_buf(false, true)
  end,
  set_title = function(self, value)
    self.title = value
  end,
  set_lines = function(self, value)
    self.lines = value
    vim.api.nvim_buf_set_lines(self.win.buf, 0, -1, false, value)
  end,
  scratch = function(self)
    self.win.buf = vim.api.nvim_create_buf(false, true)
    return self.win.buf
  end,
}
local selected = items[2]
local picker_context = {
  closed = false,
  current = function()
    return selected
  end,
}
local function preview_item(item)
  selected = item
  captured.preview({ item = item, preview = preview, picker = picker_context })
end
preview_item(items[2])
assert(not preview.number and not preview.relativenumber and preview.signcolumn == "no")
assert(vim.wait(1000, function()
  return #fake_renderer.requests == 1
end))
preview_item(items[1])
assert(vim.wait(1000, function()
  return #fake_renderer.requests == 2
end))
fake_renderer.requests[1].callback("/cache/stale.png")
assert(not attached)
fake_renderer.requests[2].callback("/cache/map.fill.png")
assert(attached.opts.src == "/cache/map.fill.png" and attached.opts.pos[1] == 3 and attached.opts.inline)
assert(fake_renderer.requests[2].foreground == "123456", vim.inspect(fake_renderer.requests[2]))
assert(preview.title == "Preview")
assert(not preview.number and not preview.relativenumber and preview.signcolumn == "no")
assert(preview.lines[1] == "map.fill" and preview.lines[5] == "Availability")
local preview_text = table.concat(preview.lines, "\n")
assert(preview_text:find("iOS 13.0", 1, true))
assert(not preview_text:find("iOS 18.0", 1, true))
assert(not preview_text:find("hierarchical", 1, true))
assert(preview.lines[9] == "Rendering modes", vim.inspect(preview.lines))
assert(preview.lines[10] == "Monochrome · Hierarchical · Palette · Multicolor", vim.inspect(preview.lines))
for line_index = 6, #preview.lines do
  assert(vim.api.nvim_strwidth(preview.lines[line_index]) <= vim.api.nvim_win_get_width(preview.win.win) - 4)
end
assert(attached.opts.pos[2] == math.floor((vim.api.nvim_win_get_width(preview.win.win) - 20) / 2))
assert(#preview.lines[3] == attached.opts.pos[2])
assert(attached.opts.width <= 32 and attached.opts.height <= 12)
assert(preview.lines[4]:find("─", 1, true))
assert(vim.api.nvim_get_hl(0, { name = "SFSymbolsPreviewHeading" }).bold)
assert(fake_renderer.cancelled == 1)
assert(fake_renderer.sessions == 1)
local localized = {
  name = "character.magnify.kn",
  glyph = "",
  availability = { ["Name availability"] = { iOS = "18.4" } },
}
preview_item(localized)
assert(vim.tbl_contains(fake_renderer.removed, "/cache/map.fill.png"))
assert(vim.wait(1000, function()
  return #fake_renderer.requests == 3
end))
fake_renderer.requests[3].callback(nil, { kind = "unavailable", message = "Unavailable on this macOS version" })
assert(preview.lines[1] == "character.magnify.kn")
assert(preview.lines[3] == "Unavailable on this macOS version")
local unavailable_lines = table.concat(preview.lines, "\n")
assert(unavailable_lines:find("iOS 18.4", 1, true))
assert(unavailable_lines:find("Rendering modes\nNot provided", 1, true))
assert(localized.glyph == "")

preview_item({ name = "renderer.throws", availability = localized.availability })
assert(vim.wait(1000, function()
  return preview.lines[3] and preview.lines[3]:find("Could not render native SF Symbol", 1, true)
end))
assert(table.concat(preview.lines, "\n"):find("iOS 18.4", 1, true))

attach_failure = true
preview_item({ name = "image.attach.failure", availability = localized.availability })
assert(vim.wait(1000, function()
  return #fake_renderer.requests == 4
end))
fake_renderer.requests[4].callback("/cache/attach.png")
assert(preview.lines[3]:find("Could not show SF Symbol PNG", 1, true))
assert(table.concat(preview.lines, "\n"):find("iOS 18.4", 1, true))
attach_failure = false

preview_item(items[1])
assert(vim.wait(1000, function()
  return #fake_renderer.requests == 5
end))
captured.on_close(picker_context)
assert(fake_renderer.cancelled == 2)
assert(fake_renderer.cleaned == 1)
fake_renderer.requests[5].callback("/cache/late.png")
assert(attached.opts.src == "/cache/map.fill.png")

-- A queued callback from the old selection must not stop the new timer.
local new_timer = vim.uv.new_timer
local timers = {}
vim.uv.new_timer = function()
  local timer = {
    start = function(self, _, _, callback)
      self.callback = callback
    end,
    stop = function(self)
      self.stopped = true
    end,
    close = function(self)
      self.closed = true
    end,
    is_closing = function(self)
      return self.closed or false
    end,
  }
  timers[#timers + 1] = timer
  return timer
end
preview_item(items[2])
timers[1].callback() -- queue schedule_wrap without running it yet
preview_item(items[1])
vim.wait(20)
assert(not timers[2].stopped, "A stale callback stopped the replacement timer")
timers[2].callback()
assert(vim.wait(1000, function()
  return #fake_renderer.requests == 6
end))
captured.on_close(picker_context)
vim.uv.new_timer = new_timer

-- Unsupported or disabled image previews must never launch native rendering.
local image = package.loaded.snacks.image
local request_count = #fake_renderer.requests
image.config.enabled = false
preview_item(localized)
assert(vim.wait(1000, function()
  return preview.lines[3] == "Snacks image previews are disabled"
end))
assert(#fake_renderer.requests == request_count)
image.config.enabled = true
image.supports_terminal = function()
  return false
end
preview_item(localized)
assert(vim.wait(1000, function()
  return preview.lines[3] == "Terminal does not support Kitty Graphics Protocol"
end))
assert(#fake_renderer.requests == request_count)
assert(table.concat(preview.lines, "\n"):find("iOS 18.4", 1, true))
image.supports_terminal = function()
  return true
end
local window_width = vim.api.nvim_win_get_width
vim.api.nvim_win_get_width = function()
  return 15
end
preview_item(localized)
assert(vim.wait(1000, function()
  return preview.lines[3] == "Preview is too small for the symbol image"
end))
assert(#fake_renderer.requests == request_count)
vim.api.nvim_win_get_width = window_width
captured.on_close(picker_context)

local registers = {}
local setreg, notify = vim.fn.setreg, vim.notify
vim.fn.setreg = function(reg, value)
  registers[reg] = value
end
vim.notify = function() end
local closed = false
local picker = {
  close = function()
    closed = true
  end,
  main = vim.api.nvim_get_current_win(),
}
captured.confirm(picker, nil)
assert(not closed)
captured.confirm(picker, items[1])
assert(closed and registers["+"] == "map.fill" and registers['"'] == "map.fill")
closed = false
vim.fn.setreg = function()
  error("clipboard failed")
end
captured.confirm(picker, items[1])
assert(not closed)
vim.fn.setreg = setreg
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '""' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
captured.actions.sfsymbols_insert(picker, items[1])
assert(vim.api.nvim_get_current_line() == '"map.fill"')
assert(closed)
plugin.setup({ glyphs = false })
plugin.open()
assert(icon_chunk(items[1])[1] == "   ")
-- Empty result sets must release the preview and still call user hooks.
local change_events = {}
plugin.setup({
  picker = {
    on_change = function(picker, item)
      change_events[#change_events + 1] = { picker = picker, item = item }
    end,
  },
})
plugin.open()
local requests_before = #fake_renderer.requests
local cleanups_before = fake_renderer.cleaned
preview_item(items[1])
assert(vim.wait(1000, function()
  return #fake_renderer.requests == requests_before + 1
end))
selected = nil
captured.on_change(picker_context, nil)
assert(fake_renderer.cleaned == cleanups_before + 1)
assert(change_events[1].picker == picker_context and change_events[1].item == nil)
fake_renderer.requests[#fake_renderer.requests].callback("/cache/empty-result-stale.png")
assert(vim.tbl_contains(fake_renderer.removed, "/cache/empty-result-stale.png"))
selected = items[1]
captured.on_change(picker_context, selected)
preview_item(selected)
assert(vim.wait(1000, function()
  return #fake_renderer.requests == requests_before + 2
end))
fake_renderer.requests[#fake_renderer.requests].callback("/cache/after-empty.png")
assert(attached.opts.src == "/cache/after-empty.png")
assert(change_events[2].item == selected)
captured.on_change(picker_context, nil)
assert(vim.tbl_contains(fake_renderer.removed, "/cache/after-empty.png"))
captured.on_close(picker_context)
vim.api.nvim_set_hl(0, "Normal", original_normal)
vim.notify = notify
vim.fn.executable = executable
catalog.load = load
package.loaded.snacks = nil
package.loaded["sfsymbols.renderer"] = nil
print("All unit tests passed")

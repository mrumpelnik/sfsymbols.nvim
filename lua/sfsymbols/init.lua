local M = {}
local preview = require("sfsymbols.preview")
local defaults = {
  cli = "/Applications/SF Symbols.app/Contents/Executables/sfsymbols",
  glyphs = true,
  picker = {
    layout = {
      preset = "default",
      config = function(layout)
        if layout.preset == "default" then
          local function set_preview_width(box)
            if type(box) ~= "table" then
              return false
            end
            if box.win == "preview" then
              box.width = 0.6
              return true
            end
            for _, child in ipairs(box) do
              if set_preview_width(child) then
                return true
              end
            end
            return false
          end
          set_preview_width(layout.layout)
        end
        return layout
      end,
    },
  },
}
local config = vim.deepcopy(defaults)

local function update_glyph_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local subdued = vim.api.nvim_get_hl(0, { name = "NonText", link = false })
  vim.api.nvim_set_hl(0, "SFSymbolsGlyph", { fg = normal.fg, bg = "NONE" })
  vim.api.nvim_set_hl(0, "SFSymbolsGlyphMissing", { fg = subdued.fg or normal.fg, bg = "NONE" })
end

local glyph_highlight_group = vim.api.nvim_create_augroup("sfsymbols.highlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = glyph_highlight_group,
  callback = update_glyph_highlights,
})
update_glyph_highlights()

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.ERROR, { title = "SF Symbols" })
end

local function copy(picker, item)
  if not item then
    return
  end
  -- Leave the picker open on clipboard failure so the selection isn't lost.
  local ok, err = pcall(function()
    vim.fn.setreg("+", item.name)
    vim.fn.setreg('"', item.name)
  end)
  if not ok then
    notify("Could not copy symbol: " .. tostring(err))
    return
  end
  picker:close()
  notify("Copied " .. item.name, vim.log.levels.INFO)
end

local function insert(picker, item)
  if not item then
    return
  end
  local win = picker.main
  picker:close()
  if not vim.api.nvim_win_is_valid(win) then
    notify("The original window is no longer available")
    return
  end
  local ok, err = pcall(vim.api.nvim_win_call, win, function()
    vim.api.nvim_put({ item.name }, "c", true, true)
  end)
  if not ok then
    notify("Could not insert symbol: " .. tostring(err))
  end
end

function M.open(opts)
  opts = opts or {}
  update_glyph_highlights()
  if vim.fn.has("mac") ~= 1 then
    notify("SF Symbols requires macOS")
    return
  end
  if vim.fn.executable(config.cli) ~= 1 then
    notify("SF Symbols CLI not found: " .. config.cli .. ". Install SF Symbols or configure cli.")
    return
  end
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    notify("sfsymbols.nvim requires folke/snacks.nvim")
    return
  end
  require("sfsymbols.catalog").load(config.cli, function(items, err)
    if not items then
      notify(err)
      return
    end
    local picker_opts = vim.tbl_deep_extend("force", {
      title = "SF Symbols",
      items = items,
      pattern = opts.query or "",
      matcher = { filename_bonus = false },
      format = function(item)
        local icon, highlight = "   ", "SFSymbolsGlyph"
        if config.glyphs then
          local glyph = item.glyph or ""
          local label = glyph == "" and "􀻃" or glyph
          local width = vim.api.nvim_strwidth(label)
          local padding = math.max(0, 2 - width)
          icon = label .. string.rep(" ", padding + 1)
          highlight = glyph == "" and "SFSymbolsGlyphMissing" or "SFSymbolsGlyph"
        end
        return { { icon, highlight }, { item.name } }
      end,
      preview = function(ctx)
        preview.show(snacks, ctx)
      end,
      confirm = copy,
      actions = { sfsymbols_insert = insert },
      win = {
        input = {
          keys = {
            ["<C-a>"] = false,
            ["<Tab>"] = false,
            ["<S-Tab>"] = false,
            ["<C-i>"] = { "sfsymbols_insert", mode = { "i", "n" }, desc = "Insert symbol name" },
          },
        },
        list = {
          keys = {
            ["<C-a>"] = false,
            ["<Tab>"] = false,
            ["<S-Tab>"] = false,
            ["<C-i>"] = { "sfsymbols_insert", desc = "Insert symbol name" },
          },
        },
      },
    }, config.picker)
    local on_change = picker_opts.on_change
    picker_opts.on_change = function(picker, item)
      if not item then
        preview.cleanup(picker)
      end
      if on_change then
        on_change(picker, item)
      end
    end
    local on_close = picker_opts.on_close
    picker_opts.on_close = function(picker)
      preview.cleanup(picker)
      if on_close then
        on_close(picker)
      end
    end
    snacks.picker.pick(picker_opts)
  end)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.api.nvim_create_user_command("SFSymbols", function(args)
    M.open({ query = args.args })
  end, { nargs = "*", desc = "Find and copy an SF Symbol name", force = true })
end

return M

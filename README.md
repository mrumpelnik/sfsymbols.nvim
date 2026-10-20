# sfsymbols.nvim

Search Apple's installed SF Symbols catalog from Neovim using Snacks picker.
Displays aligned glyphs beside names and renders the selected symbol to a
session-only PNG in the preview, followed by compact platform availability and
rendering-mode details. Copy names for SwiftUI's `Image(systemName:)` or insert them
directly into your buffer. No downloaded catalog required.

## Requirements

- macOS and Neovim 0.10+
- [snacks.nvim](https://github.com/folke/snacks.nvim) (picker enabled)
- Apple's SF Symbols app with its bundled `sfsymbols` CLI supporting
  `search --json --show-glyph` (not all older app versions include it)
- Apple's `swiftc` compiler and AppKit, used to build the bundled renderer on
  the first preview
- Snacks image enabled and a terminal that supports the Kitty Graphics
  Protocol for image previews
- A terminal/font fallback that renders SF Symbols private-use glyphs in rows
- A working Neovim clipboard provider for copying (`:checkhealth vim.provider`)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mrumpelnik/sfsymbols.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = "SFSymbols",
  keys = {
    { "<leader>fi", function() require("sfsymbols").open() end, desc = "Find SF Symbols" },
  },
  opts = {},
}
```

Without a plugin manager, clone the repository, add it to `runtimepath`, and call
`require("sfsymbols").setup()`.

## Usage

- `:SFSymbols` opens the catalog.
- `:SFSymbols check` opens it with an initial fuzzy query.
- Type to filter using Snacks' fuzzy matcher.
- `<Enter>` copies the selected **name**, not the glyph, to the system clipboard
  and unnamed register.
- `<C-i>` inserts the name **after the cursor** in the original buffer. Terminals
  that report Tab as Ctrl-I may also trigger insertion with Tab.
- `<Tab>` and `<S-Tab>` do not select multiple results. `<C-a>` is not mapped by
  this plugin and remains available for the input window's native behavior.
- Missing glyphs use a dim SF Symbol `circle.slash` in the icon column; this means
  the row has no font glyph, not that the symbol is unavailable on macOS.
  `glyphs = false` hides the column.
- The default picker gives the preview 60% of its width. It shows a bold name,
  a centered medium-size image tinted to the preview's text foreground (or
  neutral gray when that color is unavailable), then concise Availability and
  Rendering modes rows. Result rows are compact without blank spacer lines;
  icon backgrounds are transparent.
- `<Esc>` closes the picker using your Snacks configuration.

Programmatically: `require("sfsymbols").open({ query = "map" })`.

## Configuration

```lua
require("sfsymbols").setup({
  cli = "/Applications/SF Symbols.app/Contents/Executables/sfsymbols",
  glyphs = true, -- false hides the result-row icon column
  picker = {}, -- Snacks picker overrides, e.g. layout = { preset = "vertical" }
})
```

The catalog is loaded asynchronously on first use and cached in memory for the
Neovim session. All names from the app's bundled `name_availability.plist` are
included, including localized variants omitted by the CLI. The metadata is read
with macOS's built-in `plutil`, relative to the configured CLI path. If metadata
cannot be read, the picker reports an error instead of silently showing a partial
catalog. The preview summarizes platform availability from the monochrome mode,
falling back to name availability for metadata-only entries. It lists available
rendering modes separately and says `Not provided` for metadata-only symbols;
all rendering-mode records remain in the catalog data. Restart Neovim after
updating the SF Symbols app. Search is local fuzzy name matching, not the app's
keyword/alias search.
Availability reflects the installed catalog; selecting a symbol does not
guarantee it exists on your app's deployment target. Some symbols may not have
a font glyph.

Only the currently selected symbol is rendered, after a short debounce. The
small AppKit helper is compiled asynchronously on first use, then reused from
`stdpath("cache") .. "/sfsymbols.nvim"`. Its cache key includes the Swift source,
OS version, and architecture, so source edits automatically rebuild it. Builds
use unique temporary files and atomically publish one shared cached executable;
a failed build cannot delete another Neovim instance's completed helper. Exiting
during compilation stops the compiler and removes only its temporary output.
Disabled
image previews, unsupported terminals, and undersized previews skip native
rendering and retain the text details.

PNGs live in a per-picker session directory and are removed when the selection
changes, filtering leaves no results, the picker closes, or Neovim exits. The plugin also aborts its Snacks
identification job and removes that PNG's `.info` output; it never clears the
shared image cache. Snacks has no per-image eviction API, so its internal image
objects may remain in memory until Neovim exits. Symbols unavailable in the
running macOS version show an unavailable message and platform availability.

The CLI's location and response format are app-dependent. This plugin does not
modify the app, install fonts, or redistribute Apple's symbol data.

## Development

```sh
make test              # self-contained headless tests
make integration       # also tests installed SF Symbols and Snacks picker
make lint              # requires stylua
```

Integration defaults to Snacks at `stdpath("data") .. "/lazy/snacks.nvim"`.
Set `SNACKS_PATH` if it is installed elsewhere.

The self-contained tests cover the debounce race, capability fallbacks, renderer
build coalescing, independent concurrent builds, source-key invalidation,
cancellation, exit during compilation, empty-result cleanup, and artifact
ownership. Integration uses an
empty temporary cache to verify a fresh native build, PNG tinting, and real
Snacks metadata cleanup.

Source responsibilities in `lua/sfsymbols/`:

- `init.lua`: public API, configuration, picker wiring, and copy/insert actions
- `catalog.lua`: CLI catalog and complete name metadata
- `preview.lua`: formatting, layout, and asynchronous preview lifecycle
- `preview_image.lua`: transient Snacks placement and identification cleanup
- `renderer.lua` / `render.swift`: helper compilation, AppKit rendering, and PNG ownership

No generated catalog or renderer binary is tracked.

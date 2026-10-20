vim.opt.rtp:prepend(vim.fn.getcwd())
local directory = vim.fn.tempname() .. "-sfsymbols-image-test"
vim.fn.mkdir(directory, "p")
local source = directory .. "/preview.png"
local metadata = directory .. "/owned.png.info"
local unrelated = directory .. "/unrelated.txt"
local outside = directory .. "-outside.png.info"
for _, path in ipairs({ source, metadata, unrelated, outside }) do
  vim.fn.writefile({ "test" }, path)
end
local conversion = {
  steps = {
    { name = "identify", file = metadata },
    { name = "identify", file = outside },
    { name = "other", file = unrelated },
  },
  abort = function(self)
    assert(vim.uv.fs_stat(metadata), "Abort must happen before metadata removal")
    self.aborted = true
  end,
}
local ready = false
local image = {
  _convert = conversion,
  on_ready = function()
    ready = true
  end,
}
local cleaned = false
local fail_attach = false
local snacks = {
  image = {
    config = { cache = directory },
    image = {
      new = function()
        return image
      end,
    },
    placement = {
      clean = function()
        cleaned = true
      end,
    },
    buf = {
      attach = function()
        if fail_attach then
          error("attach failed")
        end
      end,
    },
  },
}
local adapter = require("sfsymbols.preview_image")
local handle = adapter.attach(snacks, 1, { src = source })
handle:cleanup()
handle:cleanup() -- idempotent
assert(cleaned and conversion.aborted)
assert(not vim.uv.fs_stat(metadata), "Owned image metadata leaked")
assert(vim.uv.fs_stat(source), "PNG ownership belongs to the renderer")
assert(vim.uv.fs_stat(unrelated) and vim.uv.fs_stat(outside), "Unrelated artifacts must be untouched")
image:on_ready()
assert(not ready, "A queued image callback must not send a released PNG")

vim.fn.writefile({ "test" }, metadata)
conversion.aborted = false
fail_attach = true
assert(not pcall(adapter.attach, snacks, 1, { src = source }))
assert(conversion.aborted and not vim.uv.fs_stat(metadata), "Failed attachment must still clean its metadata")
vim.fn.delete(directory, "rf")
vim.fn.delete(outside)
print("Transient image ownership tests passed")

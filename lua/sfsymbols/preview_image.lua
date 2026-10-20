-- Own the transient PNG's Snacks placement and identification metadata together.
-- Snacks has no per-image cache eviction API. Never clear its shared image cache.
local M = {}

function M.attach(snacks, buf, opts)
  local image = snacks.image.image.new(opts.src)
  local conversion = image._convert
  local released = false
  local handle = {}
  local on_ready = image.on_ready
  image.on_ready = function(self, ...)
    if not released then
      return on_ready(self, ...)
    end
  end

  function handle:cleanup()
    if released then
      return
    end
    released = true
    pcall(snacks.image.placement.clean, buf)
    if conversion then
      -- Native PNGs only need identify. Aborting before unlinking prevents the
      -- identify completion callback from writing its .info file afterward.
      conversion:abort()
      for _, step in ipairs(conversion.steps) do
        if
          step.name == "identify"
          and step.file ~= opts.src
          and vim.fs.dirname(step.file) == vim.fs.normalize(snacks.image.config.cache)
          and step.file:sub(-9) == ".png.info"
        then
          local ok, err, code = (vim.uv or vim.loop).fs_unlink(step.file)
          if not ok and code ~= "ENOENT" then
            vim.notify("Could not remove SF Symbols image metadata: " .. tostring(err), vim.log.levels.WARN)
          end
        end
      end
    end
  end

  local ok, err = pcall(snacks.image.buf.attach, buf, opts)
  if not ok then
    handle:cleanup()
    error(err)
  end
  return handle
end

return M

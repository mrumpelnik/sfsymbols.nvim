local M = {}
local uv = vim.uv or vim.loop
local builds = {}
local sessions = {}
local session_count = 0
local cleanup_registered = false

local function ensure_directory(directory)
  local stat = uv.fs_stat(directory)
  if stat then
    if stat.type ~= "directory" then
      return nil, "SF Symbols cache path is not a directory: " .. directory
    end
    return directory
  end

  local ok, result = pcall(vim.fn.mkdir, directory, "p")
  stat = uv.fs_stat(directory)
  if not stat or stat.type ~= "directory" then
    return nil, "Could not create SF Symbols cache directory: " .. (not ok and tostring(result) or directory)
  end
  return directory
end

local function cache_directory()
  return ensure_directory(vim.fs.joinpath(vim.fn.stdpath("cache"), "sfsymbols.nvim"))
end

local function helper_source()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.joinpath(vim.fs.dirname(source), "render.swift")
end

local function ensure_helper(directory, callback)
  local source = helper_source()
  local file, read_error = io.open(source, "rb")
  if not file then
    callback(nil, "Could not read native SF Symbols renderer: " .. tostring(read_error))
    return
  end
  local contents = file:read("*a")
  file:close()
  local host = uv.os_uname()
  local key = vim.fn.sha256(contents .. host.release .. host.machine)
  local binary = vim.fs.joinpath(directory, "render-" .. key)
  if vim.fn.executable(binary) == 1 then
    callback(binary)
    return
  end

  if builds[binary] then
    table.insert(builds[binary].callbacks, callback)
    return
  end
  local fd, temporary = uv.fs_mkstemp(vim.fs.joinpath(directory, "build-XXXXXX"))
  if not fd then
    callback(nil, "Could not create renderer build file: " .. tostring(temporary))
    return
  end
  uv.fs_close(fd)
  local build = { callbacks = { callback }, temporary = temporary }
  builds[binary] = build

  local function finish(path, err)
    build.process = nil
    builds[binary] = nil
    for _, cb in ipairs(build.callbacks) do
      cb(path, err)
    end
  end

  local ok, process = pcall(
    vim.system,
    { "swiftc", "-O", "-o", temporary, source },
    { text = true, timeout = 120000 },
    vim.schedule_wrap(function(result)
      if build.cancelled then
        pcall(uv.fs_unlink, temporary)
        return
      end
      if result.code == 0 and vim.fn.executable(temporary) == 1 then
        -- Publish only a completed executable. Another Neovim may build the
        -- same helper concurrently; neither build owns the shared cache path.
        local published, publish_error = uv.fs_rename(temporary, binary)
        if published then
          finish(binary)
          return
        end
        pcall(uv.fs_unlink, temporary)
        finish(nil, "Could not publish native SF Symbols renderer: " .. tostring(publish_error))
        return
      end
      pcall(uv.fs_unlink, temporary)
      local details = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
      if details == "" then
        details = result.code == 0 and "swiftc did not produce an executable"
          or "swiftc exited with status " .. tostring(result.code)
      end
      finish(nil, "Could not build native SF Symbols renderer: " .. details)
    end)
  )
  if not ok then
    pcall(uv.fs_unlink, temporary)
    finish(nil, "Could not start swiftc: " .. tostring(process))
  else
    build.process = process
  end
end

local function remove_file(path)
  local ok, err, code = uv.fs_unlink(path)
  if ok or code == "ENOENT" then
    return true
  end
  vim.notify("Could not remove temporary SF Symbols preview: " .. tostring(err), vim.log.levels.WARN)
  return false
end

local function remove_directory(session)
  if not session.directory then
    sessions[session] = nil
    return
  end
  local ok, err, code = uv.fs_rmdir(session.directory)
  if ok or code == "ENOENT" then
    session.directory = nil
    sessions[session] = nil
  elseif code ~= "ENOTEMPTY" then
    vim.notify("Could not remove temporary SF Symbols preview directory: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function new_job(session)
  local request = { cancelled = false }
  session.jobs[request] = true
  function request.cancel()
    if request.cancelled then
      return
    end
    request.cancelled = true
    session.jobs[request] = nil
    if request.process then
      pcall(request.process.kill, request.process, 15)
      request.process = nil
    end
    if request.path then
      session:remove(request.path)
    end
  end
  return request
end

local function render(session, name, callback, foreground)
  local request = new_job(session)
  if type(name) ~= "string" or name == "" then
    session.jobs[request] = nil
    callback(nil, { kind = "error", message = "Invalid SF Symbol name" })
    return request
  end
  if session.closed then
    session.jobs[request] = nil
    callback(nil, { kind = "error", message = "SF Symbols preview session is closed" })
    return request
  end

  local root, root_error = cache_directory()
  if not root then
    session.jobs[request] = nil
    callback(nil, { kind = "error", message = root_error })
    return request
  end

  if not session.directory then
    session_count = session_count + 1
    local suffix = table.concat({ vim.fn.getpid(), tostring(uv.hrtime()), session_count }, "-")
    local directory, directory_error = ensure_directory(vim.fs.joinpath(root, "preview-" .. suffix))
    if not directory then
      session.jobs[request] = nil
      callback(nil, { kind = "error", message = directory_error })
      return request
    end
    session.directory = directory
  end

  session.next_file = session.next_file + 1
  local image =
    vim.fs.joinpath(session.directory, string.format("%04d-%s.png", session.next_file, vim.fn.sha256(name):sub(1, 12)))
  session.paths[image] = true
  request.path = image

  local function failed(kind, message)
    session.jobs[request] = nil
    session:remove(image)
    if not request.cancelled then
      callback(nil, { kind = kind, message = message })
    end
  end

  ensure_helper(root, function(binary, build_error)
    if request.cancelled or session.closed then
      session:remove(image)
      return
    end
    if not binary then
      failed("error", build_error)
      return
    end

    local ok, process = pcall(
      vim.system,
      { binary, name, image, foreground or "8c8c8c" },
      { text = true, timeout = 30000 },
      vim.schedule_wrap(function(result)
        request.process = nil
        session.jobs[request] = nil
        if request.cancelled or session.closed then
          session:remove(image)
          return
        end
        if result.code == 0 then
          callback(image)
        elseif result.code == 3 then
          failed("unavailable", "Unavailable on this macOS version")
        else
          local details = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
          if details == "" then
            details = "Renderer exited with status " .. tostring(result.code)
          end
          failed("error", details)
        end
      end)
    )
    if not ok then
      failed("error", "Could not start native SF Symbols renderer: " .. tostring(process))
      return
    end
    request.process = process
  end)

  return request
end

function M.new_session()
  if not cleanup_registered then
    local group = vim.api.nvim_create_augroup("sfsymbols.renderer", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        for session in pairs(sessions) do
          session:cleanup()
        end
        for binary, build in pairs(builds) do
          build.cancelled = true
          if build.process then
            pcall(build.process.kill, build.process, 9)
            pcall(build.process.wait, build.process, 1000)
            build.process = nil
          end
          pcall(uv.fs_unlink, build.temporary)
          builds[binary] = nil
        end
      end,
    })
    cleanup_registered = true
  end

  local session = { closed = false, paths = {}, jobs = {}, next_file = 0 }
  sessions[session] = true

  function session:remove(path)
    if path and self.directory and vim.fs.dirname(path) == self.directory and remove_file(path) then
      self.paths[path] = nil
    end
    if self.closed then
      remove_directory(self)
    end
  end

  function session:render(name, callback, foreground)
    return render(self, name, callback, foreground)
  end

  function session:cleanup()
    self.closed = true
    for request in pairs(self.jobs) do
      request.cancel()
    end
    for path in pairs(self.paths) do
      self:remove(path)
    end
    remove_directory(self)
  end

  return session
end

return M

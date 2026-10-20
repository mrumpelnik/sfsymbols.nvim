vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname() .. "-sfsymbols-test"
vim.fn.mkdir(root, "p")
local stdpath, system, open = vim.fn.stdpath, vim.system, io.open
vim.fn.stdpath = function(kind)
  return kind == "cache" and root or stdpath(kind)
end
local source = "renderer revision one"
io.open = function(path, mode)
  if path:match("/sfsymbols/render%.swift$") then
    return {
      read = function()
        return source
      end,
      close = function() end,
    }
  end
  return open(path, mode)
end
local processes = {}
vim.system = function(args, _, callback)
  local process = { args = args, callback = callback }
  function process:kill()
    self.killed = true
  end
  function process:wait()
    assert(self.killed, "The compiler must be stopped before waiting")
    self.waited = true
    -- Model output finalized while reaping the stopped compiler.
    vim.fn.writefile({ "stopped build output" }, self.args[4])
    return { code = 137 }
  end
  processes[#processes + 1] = process
  return process
end
local function complete(process, code)
  if code == 0 then
    local output = process.args[1] == "swiftc" and process.args[4] or process.args[3]
    vim.fn.writefile({ "test output" }, output)
    if process.args[1] == "swiftc" then
      assert(vim.uv.fs_chmod(output, 493))
    end
  end
  process.callback({ code = code, stderr = code == 1 and "test failure" or "", stdout = "" })
  vim.wait(20)
end
local renderer = require("sfsymbols.renderer")
local first, second = renderer.new_session(), renderer.new_session()
local first_called, second_result = false, nil
first:render("map", function()
  first_called = true
end)
second:render("heart", function(path, err)
  second_result = { path = path, error = err }
end, "123456")
assert(#processes == 1 and processes[1].args[1] == "swiftc", "Build requests must coalesce")
first:cleanup() -- cancelled while the shared compiler is still running
complete(processes[1], 0)
assert(#processes == 2 and processes[2].args[2] == "heart")
assert(not first_called and processes[2].args[4] == "123456")
complete(processes[2], 0)
assert(second_result.path and vim.uv.fs_stat(second_result.path))
local directory = vim.fs.dirname(second_result.path)
second:cleanup()
assert(not vim.uv.fs_stat(directory))

local session = renderer.new_session()
local result
session:render("map", function(path, err)
  result = { path = path, error = err }
end)
assert(#processes == 3 and processes[3].args[1] ~= "swiftc", "Unchanged source should reuse its helper")
complete(processes[3], 3)
assert(not result.path and result.error.kind == "unavailable")
session:cleanup()

-- Changing Swift source must select a new binary, not the previous cached one.
local old_binary = processes[2].args[1]
assert(not vim.uv.fs_stat(processes[1].args[4]), "Published builds should not leave temporary output")
source = "renderer revision two"
session = renderer.new_session()
session:render("map", function(path, err)
  result = { path = path, error = err }
end)
assert(processes[4].args[1] == "swiftc" and processes[4].args[4] ~= old_binary)
complete(processes[4], 1)
assert(result.error.message:find("test failure", 1, true))
session:render("map", function(path, err)
  result = { path = path, error = err }
end)
assert(processes[5].args[1] == "swiftc", "A failed build must be retryable")
complete(processes[5], 0)
assert(processes[6].args[2] == "map")
complete(processes[6], 1)
assert(result.error.message == "test failure")
session:cleanup()

-- Cancel an in-flight render, including a file written before process exit.
session = renderer.new_session()
local called = false
local request = session:render("map", function()
  called = true
end)
local process = processes[#processes]
local pending_png = process.args[3]
vim.fn.writefile({ "partially written PNG" }, pending_png)
request.cancel()
assert(process.killed and not vim.uv.fs_stat(pending_png))
process.callback({ code = 0 })
vim.wait(20)
assert(not called)
session:cleanup()
assert(not vim.uv.fs_stat(vim.fs.dirname(pending_png)))

-- Closing a session before rendering finishes must suppress its callback.
session = renderer.new_session()
session:render("map", function()
  error("Closed session delivered a callback")
end)
process = processes[#processes]
session:cleanup()
assert(process.killed)
process.callback({ code = 1, stderr = "killed" })
vim.wait(20)
assert(not vim.uv.fs_stat(vim.fs.dirname(process.args[3])))
local count = #processes
session:render("map", function(path, err)
  assert(not path and err.message:find("closed", 1, true))
end)
assert(#processes == count)

session = renderer.new_session()
session:render("", function(path, err)
  assert(not path and err.kind == "error")
end)
assert(#processes == count)
local dispatch = vim.system
vim.system = function()
  error("spawn denied")
end
session:render("map", function(path, err)
  assert(not path and err.message:find("spawn denied", 1, true))
end)
vim.system = dispatch
session:cleanup()

session = renderer.new_session()
session:render("map", function() end)
process = processes[#processes]
complete(process, 0)
local exit_png = process.args[3]
assert(vim.uv.fs_stat(exit_png))
vim.api.nvim_exec_autocmds("VimLeavePre", {})
assert(not vim.uv.fs_stat(vim.fs.dirname(exit_png)))
-- Separate module instances model independent Neovim processes sharing a cache.
local function independent_renderer()
  return dofile(vim.fs.joinpath(vim.fn.getcwd(), "lua/sfsymbols/renderer.lua"))
end
local function binary_path()
  local host = vim.uv.os_uname()
  return vim.fs.joinpath(root, "sfsymbols.nvim", "render-" .. vim.fn.sha256(source .. host.release .. host.machine))
end
source = "concurrent build ownership"
local left = independent_renderer().new_session()
local right = independent_renderer().new_session()
local left_result, right_result
left:render("map", function(path, err)
  left_result = { path = path, error = err }
end)
local left_build = processes[#processes]
right:render("map", function(path, err)
  right_result = { path = path, error = err }
end)
local right_build = processes[#processes]
assert(left_build.args[1] == "swiftc" and right_build.args[1] == "swiftc")
assert(left_build.args[4] ~= right_build.args[4], "Independent builds must own different temporary files")
assert(not vim.uv.fs_stat(binary_path()), "An incomplete build must not be published")
complete(left_build, 0)
local left_render = processes[#processes]
assert(vim.fn.executable(binary_path()) == 1)
complete(right_build, 1)
assert(right_result.error and not right_result.path)
assert(vim.fn.executable(binary_path()) == 1, "A failed build deleted another process's executable")
complete(left_render, 0)
assert(left_result.path)
left:cleanup()
right:cleanup()

source = "two successful concurrent builds"
left, right = independent_renderer().new_session(), independent_renderer().new_session()
left:render("map", function() end)
left_build = processes[#processes]
right:render("map", function() end)
right_build = processes[#processes]
complete(left_build, 0)
left_render = processes[#processes]
complete(right_build, 0)
local right_render = processes[#processes]
assert(left_render.args[1] == binary_path() and right_render.args[1] == binary_path())
assert(not vim.uv.fs_stat(left_build.args[4]) and not vim.uv.fs_stat(right_build.args[4]))
complete(left_render, 0)
complete(right_render, 0)
left:cleanup()
right:cleanup()

-- Exit during compilation must stop/reap the compiler before removing output.
source = "exit during build"
local exiting_renderer = independent_renderer()
local exiting = exiting_renderer.new_session()
local exit_called = false
exiting:render("map", function()
  exit_called = true
end)
local exit_build = processes[#processes]
assert(exit_build.args[1] == "swiftc" and vim.uv.fs_stat(exit_build.args[4]))
vim.api.nvim_exec_autocmds("VimLeavePre", {})
assert(exit_build.killed and exit_build.waited)
assert(not vim.uv.fs_stat(exit_build.args[4]), "Exit left the compiler's temporary output")
assert(not vim.uv.fs_stat(binary_path()))
-- Even an already scheduled or late success must not publish after cancellation.
complete(exit_build, 0)
assert(not exit_called and not vim.uv.fs_stat(binary_path()))
assert(not vim.uv.fs_stat(exit_build.args[4]))

source = "exit with queued compilation success"
exiting_renderer = independent_renderer()
exiting = exiting_renderer.new_session()
exiting:render("map", function()
  error("Exit delivered a build callback")
end)
exit_build = processes[#processes]
vim.fn.writefile({ "completed build" }, exit_build.args[4])
assert(vim.uv.fs_chmod(exit_build.args[4], 493))
exit_build.callback({ code = 0, stderr = "", stdout = "" })
vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.wait(20)
assert(not vim.uv.fs_stat(binary_path()), "A queued success published after exit")
assert(not vim.uv.fs_stat(exit_build.args[4]))

for name in vim.fs.dir(vim.fs.joinpath(root, "sfsymbols.nvim")) do
  assert(not name:match("^preview%-"), "A preview directory leaked")
  assert(not name:match("^build%-"), "A temporary executable leaked")
end
vim.fn.stdpath, vim.system, io.open = stdpath, system, open
vim.fn.delete(root, "rf")
print("Renderer lifecycle tests passed")

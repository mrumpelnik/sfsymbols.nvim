local M = {}
local cache = {}
local pending = {}

function M.decode(json)
  local ok, records = pcall(vim.json.decode, json)
  if not ok or type(records) ~= "table" or not vim.islist(records) then
    return nil, "Invalid SF Symbols JSON response"
  end
  local items = {}
  for _, record in ipairs(records) do
    if type(record) ~= "table" or type(record.name) ~= "string" or record.name == "" then
      return nil, "Invalid SF Symbols catalog entry"
    end
    items[#items + 1] = {
      text = record.name,
      name = record.name,
      glyph = type(record.glyph) == "string" and record.glyph or "",
      availability = type(record.availability) == "table" and record.availability or {},
    }
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return items
end

-- The CLI omits localized variants. Keep its glyphs and richer availability,
-- but take the complete set of names from the app's metadata.
function M.merge(items, json)
  local ok, metadata = pcall(vim.json.decode, json)
  if
    not ok
    or type(metadata) ~= "table"
    or type(metadata.symbols) ~= "table"
    or type(metadata.year_to_release) ~= "table"
  then
    return nil, "Invalid SF Symbols name availability metadata"
  end
  local known = {}
  for _, item in ipairs(items) do
    known[item.name] = true
  end
  for name, year in pairs(metadata.symbols) do
    if type(name) ~= "string" or type(year) ~= "string" then
      return nil, "Invalid SF Symbols name availability entry"
    end
    if not known[name] then
      local release = metadata.year_to_release[year]
      items[#items + 1] = {
        text = name,
        name = name,
        glyph = "",
        availability = type(release) == "table" and { ["Name availability"] = release } or {},
      }
    end
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return items
end

local function supplement(cli, items, callback)
  local path = vim.fn.fnamemodify(cli, ":h:h") .. "/Resources/Metadata/name_availability.plist"
  local ok, err = pcall(
    vim.system,
    { "/usr/bin/plutil", "-convert", "json", "-o", "-", path },
    {
      text = true,
      timeout = 15000,
    },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        callback(
          nil,
          "Could not read full SF Symbols catalog: "
            .. vim.trim(result.stderr or "")
            .. " (exit "
            .. result.code
            .. "). Expected metadata at "
            .. path
        )
        return
      end
      callback(M.merge(items, result.stdout or ""))
    end)
  )
  if not ok then
    callback(nil, "Could not read SF Symbols metadata: " .. tostring(err))
  end
end

-- Cache only in memory: the next Neovim session sees any app updates.
function M.load(cli, callback)
  if cache[cli] then
    callback(cache[cli])
    return
  end
  if pending[cli] then
    table.insert(pending[cli], callback)
    return
  end
  pending[cli] = { callback }
  local function finish(items, err)
    cache[cli] = items
    local callbacks = pending[cli]
    pending[cli] = nil
    for _, cb in ipairs(callbacks) do
      cb(items, err)
    end
  end
  local ok, err = pcall(
    vim.system,
    { cli, "search", "", "--limit", "0", "--json", "--show-glyph" },
    {
      text = true,
      timeout = 15000,
    },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        finish(nil, "SF Symbols search failed: " .. vim.trim(result.stderr or "") .. " (exit " .. result.code .. ")")
        return
      end
      local items, decode_err = M.decode(result.stdout or "")
      if not items then
        finish(nil, decode_err)
        return
      end
      supplement(cli, items, finish)
    end)
  )
  if not ok then
    finish(nil, "Could not run SF Symbols: " .. tostring(err))
  end
end

return M

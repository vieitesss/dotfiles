-- Rex database: a small key-value store for state that should outlive one
-- action or script, kept as one JSON file per server.
--
--   local db = require("db")
--   db.set("key", { any = "json value" })
--   db.get("key")
--
-- The file is state, not configuration, so it lives outside this directory:
-- $REX_DB when set, otherwise $XDG_STATE_HOME/rex/db.json.

local M = {}

function M.path()
  local path = os.getenv("REX_DB")
  if path ~= nil and path ~= "" then return path end
  local state = os.getenv("XDG_STATE_HOME")
  if state == nil or state == "" then
    state = (os.getenv("HOME") or "") .. "/.local/state"
  end
  return state .. "/rex/db.json"
end

-- Read every key. Missing or unreadable files are empty databases. Invalid
-- JSON also yields an empty database, with a warning.
local function load()
  local file = io.open(M.path(), "r")
  if file == nil then return {} end
  local text = file:read("*a")
  file:close()
  local data, err = rex.json.decode(text)
  if type(data) ~= "table" then
    rex.log("warn", "db: ignoring " .. M.path() .. ": " .. tostring(err or "not an object"))
    return {}
  end
  return data
end

function M.get(key)
  return load()[key]
end

-- Run fn while holding the database's lock, a directory beside the file:
-- mkdir either creates it or fails, so only one writer at a time gets it.
-- A lock older than about two seconds belongs to a writer that died, and
-- is taken over.
local function locked(fn)
  local path = M.path()
  rex.exec({ "mkdir", "-p", path:match("^(.*)/[^/]*$") })
  local lock = path .. ".lock"
  for attempt = 1, 40 do
    local made = rex.exec({ "mkdir", lock }, { stderr = false })
    if made ~= nil and made.ok then break end
    if attempt == 40 then
      rex.log("warn", "db: taking over the stale lock " .. lock)
    else
      rex.exec({ "sleep", "0.05" })
    end
  end
  local ok, err = pcall(fn, path)
  os.remove(lock)
  if not ok then error(err, 0) end
end

-- Set key to value, or remove it when value is nil. The lock keeps another
-- writer from losing this change, and the file is replaced by a rename, so
-- a reader never sees half of it.
function M.set(key, value)
  locked(function(path)
    local data = load()
    data[key] = value
    local text, err = rex.json.encode(data, { indent = true })
    if text == nil then error("db: " .. tostring(err), 0) end

    -- Only the lock holder writes, so one temporary name is enough. It sits
    -- beside the database so the rename stays on the same filesystem.
    local tmp = path .. ".tmp"
    local file, open_err = io.open(tmp, "w")
    if file == nil then error("db: " .. tostring(open_err), 0) end
    file:write(text, "\n")
    file:close()
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed then error("db: " .. tostring(rename_err), 0) end
  end)
end

return M

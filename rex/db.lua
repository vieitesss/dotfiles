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

-- Every key. A missing file is an empty database; so is an unreadable one,
-- with a warning, so stale state never breaks a key binding.
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

-- Set key to value, or remove it when value is nil. The file is replaced by
-- a rename, so a reader never sees half of it.
function M.set(key, value)
  local data = load()
  data[key] = value
  local text, err = rex.json.encode(data, { indent = true })
  if text == nil then error("db: " .. tostring(err), 0) end

  local path = M.path()
  rex.exec({ "mkdir", "-p", path:match("^(.*)/[^/]*$") })
  -- A table's address differs per process, so two writers never share a
  -- temporary file.
  local tmp = path .. "." .. tostring({}):match("%w+$") .. ".tmp"
  local file, open_err = io.open(tmp, "w")
  if file == nil then error("db: " .. tostring(open_err), 0) end
  file:write(text, "\n")
  file:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then error("db: " .. tostring(rename_err), 0) end
end

return M

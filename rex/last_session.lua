-- The session to go back to, across every server the app shows sessions of.
--
-- last_session_watch.lua records each session the app shows on its server.
-- Each server keeps its own record in its Rex database:
--
--   { current = { session_id = ..., at = ... }, previous = { ... } }
--
-- where `at` is when the app last showed that session, in seconds since the
-- epoch. The session to go back to is the one shown most recently, other
-- than the one shown now, over the records of all servers.

local db = require("db")

local M = {}
local key = "last_session"

-- This server's record.
function M.state()
  return db.get(key) or {}
end

-- Record that the app shows session `id` of this server at time `now`
-- (default: the current time).
function M.record(id, now)
  now = now or os.time()
  local state = M.state()
  local current = state.current
  local previous = current
  if current ~= nil and current.session_id == id then
    -- Shown again: only the time moves, at most once a second.
    if current.at == now then return end
    previous = state.previous
  end
  db.set(key, { current = { session_id = id, at = now }, previous = previous })
end

-- The entry shown most recently other than `current_id`, over `states`,
-- a list of server records, and the record it came from. On a tie the
-- earlier record wins. Returns nil when there is no such entry.
function M.target(current_id, states)
  local best, best_state
  for _, state in ipairs(states) do
    for _, field in ipairs({ "current", "previous" }) do
      local entry = state[field]
      if entry ~= nil and type(entry.at) == "number" and entry.session_id ~= current_id
          and (best == nil or entry.at > best.at) then
        best, best_state = entry, state
      end
    end
  end
  return best, best_state
end

return M

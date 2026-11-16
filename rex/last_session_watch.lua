-- Records every session of this server that the app shows, so the
-- last_session action knows where to go back to. init.lua starts it on each
-- server:
--
--   rex do --all ~/.config/rex/last_session_watch.lua
--
-- Rex has no event for the app showing another session. The app does send
-- terminal.size_changed, though the events reference leaves it out, each
-- time it shows a terminal, even when the size is unchanged. The event's
-- owner identifies the sending client, so an app-owned resize marks the
-- session as shown.

local db = require("db")
local last_session = require("last_session")

-- One watcher at a time: starting a new one, as each load of init.lua does,
-- makes the older one stop.
local watcher_key = "last_session_watcher"
local token = os.time() .. " " .. tostring({})
db.set(watcher_key, token)
rex.every(5, function()
  if db.get(watcher_key) ~= token then rex.stop() end
end)

-- Programs can also resize a terminal, in a session nobody is looking at.
local function is_app(client_id)
  local listed = rex.call("client.list")
  for _, c in ipairs(listed and listed.clients or {}) do
    if c.client_id == client_id then
      return c.info ~= nil and c.info.kind == "app"
    end
  end
  return false
end

rex.on("terminal.size_changed", function(ctx, ev)
  if is_app(ev.owner) then last_session.record(ctx.session_id) end
end)

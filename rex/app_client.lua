-- The app's client on another server. Each server the app connects to gives
-- it a client ID of its own, so a client ID from one server is no use on
-- another.
--
--   local app_client = require("app_client")
--   app_client.on(rex.server("rpi"), rex, ctx.client_id)

local M = {}

-- Find the same app on another server. `client_id` is the app's ID on
-- `here`. Look up its label, then return the app client on `api` with that
-- label. If no label matches, return any app client on `api`. Return nil
-- when no app is connected to `api`.
function M.on(api, here, client_id)
  local label
  for _, c in ipairs((here.call("client.list") or {}).clients or {}) do
    if c.client_id == client_id then label = c.info and c.info.label end
  end
  local match, any
  for _, c in ipairs((api.call("client.list") or {}).clients or {}) do
    if c.info and c.info.kind == "app" then
      any = c.client_id
      if label ~= nil and c.info.label == label then match = c.client_id end
    end
  end
  return match or any
end

return M

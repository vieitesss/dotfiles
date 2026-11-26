-- Run by tests/rex-db.test.sh, which sets REX_DB and REX_CONFIG_DIR.
package.path = os.getenv("REX_CONFIG_DIR") .. "/?.lua;" .. package.path

local db = require("db")
local last_session = require("last_session")

local function check(name, got, want)
  if got ~= want then
    error(name .. ": got " .. tostring(got) .. ", want " .. tostring(want), 0)
  end
end

local function id(entry) return entry and entry.session_id end

-- db
check("path", db.path(), os.getenv("REX_DB"))
check("missing file", db.get("a"), nil)
db.set("a", { n = 1 })
db.set("b", "text")
check("get table", db.get("a").n, 1)
check("get string", db.get("b"), "text")
db.set("b", nil)
check("removed", db.get("b"), nil)
check("other key kept", db.get("a").n, 1)

local file = io.open(db.path(), "w")
file:write("not json")
file:close()
check("corrupt file", db.get("a"), nil)
db.set("a", 2)
check("corrupt file replaced", db.get("a"), 2)

-- last_session.record keeps this server's record.
local function target(current_id) return id(last_session.target(current_id, { last_session.state() })) end

check("nothing recorded", target("s1"), nil)
last_session.record("s1", 10)
check("only the shown session", target("s1"), nil)
last_session.record("s1", 10)
last_session.record("s2", 10)
check("same-second switch keeps previous", target("s2"), "s1")

last_session.record("s2", 11)
check("back", target("s2"), "s1")
last_session.record("s1", 12)
check("toggle", target("s1"), "s2")
last_session.record("s1", 13)
check("shown again keeps previous", target("s1"), "s2")
last_session.record("s3", 14)
check("third session replaces previous", target("s3"), "s1")
check("refreshed visit beats another server", id(last_session.target("s3", {
  last_session.state(), { current = { session_id = "remote", at = 12 } },
})), "s1")
check("record preserves other DB keys", db.get("a"), 2)

local before = os.time()
last_session.record("clock")
local at = last_session.state().current.at
check("default timestamp is current", at >= before and at <= os.time(), true)

-- last_session.target merges the records of several servers.
local mac = { current = { session_id = "A", at = 3 }, previous = { session_id = "C", at = 1 } }
local rpi = { current = { session_id = "B", at = 2 }, server = "rpi" }
local to, target_state = last_session.target("A", { mac, rpi })
check("other server", id(to), "B")
check("its server", target_state.server, "rpi")
check("from the other server", id(last_session.target("B", { mac, rpi })), "A")

-- mac:A, rpi:B, mac:A, mac:C: back from C is A, not B.
mac = { current = { session_id = "C", at = 4 }, previous = { session_id = "A", at = 3 } }
check("shown again wins", id(last_session.target("C", { mac, rpi })), "A")

check("tie: earlier record", id(last_session.target("X",
  { { current = { session_id = "P", at = 5 } }, { current = { session_id = "Q", at = 5 } } })), "P")
check("entry without time", last_session.target("X", { { current = { session_id = "P" } } }), nil)

check("empty records have no target", last_session.target("X", { {}, {} }), nil)
check("current excluded in every record", last_session.target("X", {
  { current = { session_id = "X", at = 9 } },
  { previous = { session_id = "X", at = 8 } },
}), nil)

local tied = { current = { session_id = "P", at = 5 }, previous = { session_id = "Q", at = 5 } }
check("tie within record prefers current", id(last_session.target("X", { tied })), "P")
check("excluding tied current keeps previous", id(last_session.target("P", { tied })), "Q")
local older = { previous = { session_id = "old", at = 0 }, server = "rpi" }
local entry, state = last_session.target("X", {
  { current = { session_id = "bad", at = "9" } }, older,
})
check("non-numeric time skipped", id(entry), "old")
check("previous-only record keeps server", state.server, "rpi")

-- Load the config with a fake Rex; no live actions run.
local function configure(fake)
  local init = assert(loadfile(os.getenv("REX_CONFIG_DIR") .. "/init.lua"))
  setfenv(init, setmetatable({ rex = fake }, { __index = _G }))
  init()
end

local function route(name, pressed_server, current_id, mac_state, rpi_state, want_server, want_id, want_client)
  db.set("last_session", mac_state)
  local actions, bindings, selected = {}, {}, nil
  local missing = false
  local ctx = { server = pressed_server, session_id = current_id, client_id = "key-client", block_id = "block" }
  local sessions = { mac = { "A", "C" }, rpi = { "B", "D" } }
  local function select_session(server, action, args, client_id)
    if action ~= "session.select" then error("unexpected client action: " .. action, 0) end
    for _, session_id in ipairs(sessions[server]) do
      if session_id == args.session_id and not (missing and session_id == want_id) then
        selected = { server = server, id = session_id, client = client_id }
        return {}
      end
    end
    return nil, "SessionNotFoundOnServerError"
  end
  local function call(server, method, args)
    if method == "client.action" then
      return { result = actions[args.action](), client_actions = {} }
    elseif method == "session.list" then
      local listed = {}
      for _, session_id in ipairs(sessions[server]) do
        if not (missing and session_id == want_id) then
          table.insert(listed, { session_id = session_id })
        end
      end
      return { sessions = listed }
    elseif method == "client.list" then
      return { clients = {
        { client_id = "key-client", info = { kind = "cli", label = "desk" } },
        { client_id = "matched-app", info = { kind = "app", label = "desk" } },
        { client_id = "other-app", info = { kind = "app", label = "other" } },
      } }
    elseif method == "client.perform" then
      -- The app resolves session.select on the server receiving the call,
      -- not on the server whose database supplied the target.
      return select_session(server, args.action, args.args, args.client_id)
    end
    error(name .. ": unexpected call " .. method, 0)
  end
  local fake = {
    action = function(action) actions[action.name] = action.run end,
    set = function() end,
    match = {
      under = function(dir) return { under = dir } end,
      uuid = { uuid = true },
    },
    exec = { start = function() end },
    bind = function(key, action) bindings[key] = action end,
    servers = function() return { "rpi" } end,
    server = function(server)
      return { call = function(method, args) return call(server, method, args) end }
    end,
    call = function(method, args) return call(pressed_server or "mac", method, args) end,
    client = { queue = function(action, args)
      local _, err = select_session("mac", action, args, "key-client")
      if err then error(err, 0) end
    end },
    log = function(_, message) error(name .. ": " .. message, 0) end,
  }
  configure(fake)
  -- The remote server runs the same state action against its own database.
  local local_state = actions.last_session_state
  actions.last_session_state = function()
    db.set("last_session", rpi_state)
    local state = local_state()
    db.set("last_session", mac_state)
    return state
  end
  local switch = assert(actions[bindings["ctrl+space>tab"]], "previous-session key is not bound")
  switch(ctx)
  check(name .. " server", selected and selected.server, want_server)
  check(name .. " target", selected.id, want_id)
  check(name .. " client", selected.client, want_client)
  if pressed_server == nil then
    missing, selected = true, nil
    local ok, err = pcall(switch, ctx)
    check(name .. " deleted target fails", ok, false)
    check(name .. " deleted target message", err,
      (want_server == "mac" and "" or "rpi: ") .. "the previous session no longer exists")
    check(name .. " deleted target is not selected", selected, nil)
  end
end

local function record(current, at, previous, previous_at)
  return {
    current = { session_id = current, at = at },
    previous = previous and { session_id = previous, at = previous_at },
  }
end
route("Mac to Mac", nil, "A", record("A", 3, "C", 2), record("B", 1), "mac", "C", "key-client")
route("Mac to rpi", nil, "A", record("A", 3), record("B", 2), "rpi", "B", "matched-app")
route("rpi to Mac", "rpi", "B", record("A", 2), record("B", 3), "mac", "A", "key-client")
route("rpi to rpi", "rpi", "B", record("A", 1), record("B", 3, "D", 2), "rpi", "D", "matched-app")

print("ok")

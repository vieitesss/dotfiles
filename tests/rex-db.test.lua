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
check("first timestamp", last_session.state().current.at, 10)
check("first session has no previous", last_session.state().previous, nil)

local set = db.set
local writes = 0
db.set = function(...)
  writes = writes + 1
  return set(...)
end
last_session.record("s1", 10)
check("same session and second does not write", writes, 0)
last_session.record("s2", 10)
check("different session in the same second writes", writes, 1)
check("same-second switch keeps previous", target("s2"), "s1")
db.set = set

last_session.record("s2", 11)
check("back", target("s2"), "s1")
check("previous", last_session.state().previous.session_id, "s1")
last_session.record("s1", 12)
check("toggle", target("s1"), "s2")
last_session.record("s1", 13)
check("shown again keeps previous", target("s1"), "s2")
check("shown again moves the time", last_session.state().current.at, 13)
check("shown again keeps previous time", last_session.state().previous.at, 11)
last_session.record("s3", 14)
check("third session replaces previous", target("s3"), "s1")
check("third session keeps refreshed time", last_session.state().previous.at, 13)
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

local empty_target, empty_state = last_session.target("X", { {}, {} })
check("empty records have no target", empty_target, nil)
check("empty records have no target state", empty_state, nil)
check("no servers", last_session.target("X", {}), nil)
check("current excluded in every record", last_session.target("X", {
  { current = { session_id = "X", at = 9 } },
  { previous = { session_id = "X", at = 8 } },
}), nil)

local tied = { current = { session_id = "P", at = 5 }, previous = { session_id = "Q", at = 5 } }
check("tie within record prefers current", last_session.target("X", { tied }), tied.current)
check("excluding tied current keeps previous", last_session.target("P", { tied }), tied.previous)
local older = { previous = { session_id = "old", at = 0 }, server = "rpi" }
local entry, state = last_session.target("X", {
  { current = { session_id = "bad", at = "9" } }, older,
})
check("non-numeric time skipped", entry, older.previous)
check("previous-only record keeps server", state, older)
check("merge does not change record", older.current, nil)

-- Load only the last-session bindings with a fake Rex; no live actions run.
local init = assert(io.open(os.getenv("REX_CONFIG_DIR") .. "/init.lua", "r"))
local lines, reading = {}, false
for line in init:lines() do
  if line == "-- Keep last_session_watch.lua running, to record each session the app shows." then
    reading = true
  end
  if reading then table.insert(lines, line) end
  if line == 'bind("tab", "last_session")' then break end
end
init:close()
check("last-session bindings found", lines[#lines], 'bind("tab", "last_session")')
local configure = assert(loadstring("return function(rex, last_session, app_client, bind)\n"
  .. table.concat(lines, "\n") .. "\nend"))()

local function route(name, pressed_server, current_id, mac_state, rpi_state, want_method, want_id, want_client)
  db.set("last_session", mac_state)
  local actions, selected = {}, nil
  local missing = false
  local ctx = { server = pressed_server, session_id = current_id, client_id = "key-client", block_id = "block" }
  local function call(server, method, args, via)
    if method == "client.action" then
      check(name .. " state transport", via, "server")
      check(name .. " state server", server, "rpi")
      check(name .. " state action", args.action, "last_session_state")
      return { result = rpi_state, client_actions = {} }
    elseif method == "session.list" then
      check(name .. " target can be queried", want_method ~= "context", true)
      check(name .. " validation transport", via, want_method == "queue" and "context" or "server")
      check(name .. " validation server", server, want_method == "queue" and "mac" or "rpi")
      return { sessions = missing and {} or { { session_id = want_id } } }
    elseif method == "client.list" then
      return { clients = {
        { client_id = "key-client", info = { kind = "cli", label = "desk" } },
        { client_id = "matched-app", info = { kind = "app", label = "desk" } },
        { client_id = "other-app", info = { kind = "app", label = "other" } },
      } }
    elseif method == "client.perform" then
      check(name .. " perform action", args.action, "session.select")
      check(name .. " perform origin", args.origin, "key")
      check(name .. " perform server", server, "rpi")
      selected = { method = via, id = args.args.session_id, client = args.client_id }
      return {}
    end
    error(name .. ": unexpected call " .. method, 0)
  end
  local fake = {
    action = function(action) actions[action.name] = action.run end,
    exec = { start = function() end },
    servers = function() return { "rpi" } end,
    server = function(server)
      check(name .. " named server", server, "rpi")
      return { call = function(method, args) return call(server, method, args, "server") end }
    end,
    call = function(method, args) return call(pressed_server or "mac", method, args, "context") end,
    client = { queue = function(action, args)
      check(name .. " queue context", pressed_server, nil)
      check(name .. " queued action", action, "session.select")
      selected = { method = "queue", id = args.session_id }
    end },
    session = { describe_block = function(args)
      check(name .. " block owner server", pressed_server, "rpi")
      check(name .. " pressed block", args.block_id, "block")
      return { block = { owner = "owner-app" } }
    end },
    log = function(_, message) error(name .. ": " .. message, 0) end,
  }
  configure(fake, last_session, require("app_client"), function(key, action)
    check(name .. " binding key", key, "tab")
    check(name .. " binding action", action, "last_session")
  end)
  check(name .. " local state action", actions.last_session_state().current.session_id, mac_state.current.session_id)
  actions.last_session(ctx)
  check(name .. " method", selected and selected.method, want_method)
  check(name .. " target", selected.id, want_id)
  check(name .. " client", selected.client, want_client)
  if want_method ~= "context" then
    missing, selected = true, nil
    local ok, err = pcall(actions.last_session, ctx)
    check(name .. " deleted target fails", ok, false)
    check(name .. " deleted target message", err,
      (want_method == "queue" and "" or "rpi: ") .. "the previous session no longer exists")
    check(name .. " deleted target is not selected", selected, nil)
  end
end

local function record(current, at, previous, previous_at)
  return {
    current = { session_id = current, at = at },
    previous = previous and { session_id = previous, at = previous_at },
  }
end
route("Mac to Mac", nil, "A", record("A", 3, "C", 2), record("B", 1), "queue", "C")
route("Mac to rpi", nil, "A", record("A", 3), record("B", 2), "server", "B", "matched-app")
route("rpi to Mac", "rpi", "B", record("A", 2), record("B", 3), "context", "A", "owner-app")
route("rpi to rpi", "rpi", "B", record("A", 1), record("B", 3, "D", 2), "server", "D", "matched-app")

print("ok")

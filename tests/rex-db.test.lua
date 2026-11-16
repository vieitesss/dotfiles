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
local function target(from) return id(last_session.target(from, { last_session.state() })) end

check("nothing recorded", target("s1"), nil)
last_session.record("s1", 10)
check("only the shown session", target("s1"), nil)
last_session.record("s2", 11)
check("back", target("s2"), "s1")
check("previous", last_session.state().previous.session_id, "s1")
last_session.record("s1", 12)
check("toggle", target("s1"), "s2")
last_session.record("s1", 13)
check("shown again keeps previous", target("s1"), "s2")
check("shown again moves the time", last_session.state().current.at, 13)

-- last_session.target merges the records of several servers.
local mac = { current = { session_id = "A", at = 3 }, previous = { session_id = "C", at = 1 } }
local rpi = { current = { session_id = "B", at = 2 }, server = "rpi" }
local to, from = last_session.target("A", { mac, rpi })
check("other server", id(to), "B")
check("its server", from.server, "rpi")
check("from the other server", id(last_session.target("B", { mac, rpi })), "A")

-- mac:A, rpi:B, mac:A, mac:C: back from C is A, not B.
mac = { current = { session_id = "C", at = 4 }, previous = { session_id = "A", at = 3 } }
check("shown again wins", id(last_session.target("C", { mac, rpi })), "A")

check("tie: earlier record", id(last_session.target("X",
  { { current = { session_id = "P", at = 5 } }, { current = { session_id = "Q", at = 5 } } })), "P")
check("entry without time", last_session.target("X", { { current = { session_id = "P" } } }), nil)

print("ok")

-- Run by tests/rex-snapshot.test.sh, which sets REX_DB and REX_CONFIG_DIR.
package.path = os.getenv("REX_CONFIG_DIR") .. "/?.lua;" .. package.path

local snapshot = require("snapshot")

local function check(name, got, want)
  if got ~= want then
    error(name .. ": got " .. tostring(got) .. ", want " .. tostring(want), 0)
  end
end

local function cmd(line, id) return snapshot.command(snapshot.words(line), id) end

-- Shells restore as bare shells.
check("login shell", cmd("-zsh"), nil)
check("zsh", cmd("/bin/zsh"), nil)
check("nothing", cmd(""), nil)

-- Claude resumes its conversation, keeping its other flags.
check("bare claude", cmd("claude", "abc"), "claude --resume abc")
check("claude resume replaced",
  cmd("/x/claude --resume old --model m --permission-mode auto", "new"),
  "/x/claude --resume new --model m --permission-mode auto")
check("claude -c dropped", cmd("claude -c --model m", "id"), "claude --resume id --model m")
check("claude picker -r dropped", cmd("claude -r --model m", "id"), "claude --resume id --model m")
check("claude --resume= dropped", cmd("claude --resume=old", "id"), "claude --resume id")
check("claude --session-id dropped", cmd("claude --session-id old x", "id"), "claude --resume id x")
check("claude unknown session", cmd("claude --model m"), "claude --model m")

-- pi reopens its session file, keeping its other flags.
check("bare pi", cmd("pi", "/s.jsonl"), "pi --session /s.jsonl")
check("pi pick flags dropped", cmd("pi -c --session old --fork f --model m", "/s.jsonl"),
  "pi --session /s.jsonl --model m")
check("pi unknown session", cmd("pi --model m"), "pi --model m")

-- Anything else runs again, quoted for the shell.
check("leaf", cmd("leaf diff"), "leaf diff")
check("quoted", snapshot.join({ "echo", "it's", "a b" }), [[echo 'it'\''s' 'a b']])

print("ok")

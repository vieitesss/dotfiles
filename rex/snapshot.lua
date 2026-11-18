-- Restart the programs that were running in each pane after the server
-- restarts, for example to apply an update. init.lua keeps it running:
--
--   rex do --all ~/.config/rex/snapshot.lua
--
-- The server already saves its sessions when it stops and restores them
-- when it starts, keeping session and block IDs, layouts and directories,
-- but each pane comes back as a bare shell. So the snapshot only records,
-- per block, the command to type into that shell again. Agents come back on
-- the conversation they had open:
--
--   claude  --resume <session ID>, from ~/.claude/sessions/<pid>.json
--   pi      --session <session file>, from ~/.pi/agent/pids/<pid>.json
--   other   the same command line again
--
-- The server has no event for stopping, so the snapshot is saved on start
-- and every 30 seconds; reloading the config saves it at once. A snapshot
-- from an earlier server process, told apart by its instance_id, means the
-- server has just restarted: it is resumed instead. Command lines come from
-- ps, which joins arguments with spaces, so an argument that holds a space
-- comes back split.

local db = require("db")

local M = {}

local key = "snapshot"
local watcher_key = "snapshot_watcher"
local shells = { zsh = true, bash = true, sh = true, fish = true, login = true }

-- Split a ps command line into words.
function M.words(line)
  local out = {}
  for w in (line or ""):gmatch("%S+") do table.insert(out, w) end
  return out
end

-- Quote a word for the shell when it needs it.
local function quote(word)
  if word:match("^[%w%-%._/=:@,+%%]+$") then return word end
  return "'" .. word:gsub("'", "'\\''") .. "'"
end

function M.join(words)
  local out = {}
  for _, w in ipairs(words) do table.insert(out, quote(w)) end
  return table.concat(out, " ")
end

-- Read a JSON file, or nil.
local function read_json(path)
  local file = io.open(path, "r")
  if file == nil then return nil end
  local data = rex.json.decode(file:read("*a"))
  file:close()
  return type(data) == "table" and data or nil
end

local home = os.getenv("HOME") or ""

-- The agents whose conversation comes back. Per agent: the flags that pick a
-- conversation, and whether each takes a value; the flag that reopens one;
-- and the conversation the process `pid` has open, as the agent records it.
local agents = {
  claude = {
    pick = {
      ["--resume"] = "optional", ["-r"] = "optional",
      ["--continue"] = "none", ["-c"] = "none",
      ["--session-id"] = "required", ["--fork-session"] = "none",
    },
    reopen = "--resume",
    session = function(pid)
      local data = read_json(home .. "/.claude/sessions/" .. pid .. ".json")
      return data and data.sessionId
    end,
  },
  pi = {
    pick = {
      ["--continue"] = "none", ["-c"] = "none",
      ["--resume"] = "none", ["-r"] = "none",
      ["--session"] = "required", ["--session-id"] = "required",
      ["--fork"] = "required", ["--no-session"] = "none",
    },
    reopen = "--session",
    -- Recorded by pi/agent/extensions/session-pid.ts. pi writes the file
    -- only once the conversation has a message.
    session = function(pid)
      local data = read_json(home .. "/.pi/agent/pids/" .. pid .. ".json")
      local path = data and data.sessionFile
      if type(path) ~= "string" or not io.open(path, "r") then return nil end
      return path
    end,
  },
}

-- The program name of a command line.
local function program(words)
  return words[1] and words[1]:match("([^/]+)$")
end

-- The command to restore a pane whose foreground program ran `words`.
-- `session` is the conversation an agent had open, when known. Returns nil
-- for a bare shell.
function M.command(words, session)
  local name = program(words)
  if name == nil or name:sub(1, 1) == "-" or shells[name] then return nil end

  local agent = agents[name]
  if agent == nil or session == nil then return M.join(words) end

  local out, i = { words[1] }, 2
  while i <= #words do
    local w = words[i]
    local flag = w:match("^(%-%-?[%w-]+)=") or w
    local kind = agent.pick[flag]
    if kind == nil then
      table.insert(out, w)
    elseif flag == w and (kind == "required"
        or (kind == "optional" and words[i + 1] and words[i + 1]:sub(1, 1) ~= "-")) then
      i = i + 1 -- also drop the flag's value
    end
    i = i + 1
  end
  table.insert(out, 2, agent.reopen)
  table.insert(out, 3, session)
  return M.join(out)
end

-- The command to restore block `block_id` of session `session_id`, or nil
-- when it runs a bare shell. Also returns whether the block answered.
local function block_command(session_id, block_id)
  local proc = rex.call("block.method", {
    session_id = session_id, block_id = block_id, method = "process",
  })
  local fg = proc and proc.foreground
  if fg == nil then return nil, false end
  local ps = rex.exec({ "ps", "-o", "args=", "-p", tostring(fg.pid) }, { stderr = false })
  local words = M.words(ps and ps.stdout)
  local agent = agents[program(words) or ""]
  return M.command(words, agent and agent.session(fg.pid)), true
end

-- Every session of this server, attached, since a script may only look
-- into the sessions it is attached to.
local function attach_all()
  local list = (rex.call("session.list") or {}).sessions or {}
  for _, s in ipairs(list) do rex.call("session.attach", { session_id = s.session_id }) end
  return list
end

-- The panes of this server that run something other than a shell.
local function capture()
  local panes = {}
  for _, s in ipairs(attach_all()) do
    local listed = rex.call("session.list_blocks", { session_id = s.session_id })
    for _, b in ipairs(listed and listed.blocks or {}) do
      if b.creator_name == "com.superlogical.terminal" then
        local command = block_command(s.session_id, b.block_id)
        if command ~= nil then
          table.insert(panes, {
            session = s.label, session_id = s.session_id,
            block_id = b.block_id, command = command,
          })
        end
      end
    end
  end
  local status = rex.call("server.status") or {}
  return { instance_id = status.instance_id, panes = panes }
end

-- Save the snapshot. Writes only when the panes changed.
local function save()
  local snap = capture()
  local old = db.get(key)
  if old == nil or old.instance_id ~= snap.instance_id
      or rex.json.encode(old.panes) ~= rex.json.encode(snap.panes) then
    snap.saved_at = os.time()
    db.set(key, snap)
  end
end

-- Type each saved command into its block again, when that block still
-- exists and runs a bare shell.
local function resume(snap)
  attach_all()
  local resumed, skipped = 0, 0
  for _, p in ipairs(snap.panes or {}) do
    local running, answered = block_command(p.session_id, p.block_id)
    -- A restored shell may not have started yet: give it a few seconds.
    for _ = 1, 20 do
      if answered then break end
      rex.sleep(0.25)
      running, answered = block_command(p.session_id, p.block_id)
    end
    if answered and running == nil then
      rex.call("block.method", {
        session_id = p.session_id, block_id = p.block_id,
        method = "write", args = { data = p.command .. "\n" },
      })
      resumed = resumed + 1
    else
      skipped = skipped + 1
      rex.log("info", "snapshot: not resuming " .. p.session .. " " .. p.block_id
        .. (answered and ": busy" or ": gone"))
    end
  end
  rex.log("info", "snapshot: resumed " .. resumed .. ", skipped " .. skipped)
end

-- Loaded with require, as the test does: only the module.
if (...) == "snapshot" then return M end

-- One watcher at a time: starting a new one, as each load of init.lua does,
-- makes the older one stop.
local token = os.time() .. " " .. tostring({})
db.set(watcher_key, token)

local snap = db.get(key)
if snap ~= nil and snap.instance_id ~= (rex.call("server.status") or {}).instance_id then
  -- Resumed programs need a moment to start, so the first save waits one
  -- interval and records them, not their shells.
  resume(snap)
else
  save()
end

rex.every(30, function()
  if db.get(watcher_key) ~= token then rex.stop() end
  save()
end)

-- Project session picker: choose a project directory with fzf, then switch to
-- its session, creating it first when it does not exist. Other hosts (rex
-- hosts) add their sessions and project directories, listed as HOST:PATH.
--
-- Run it inside a Rex terminal: rex do ~/.config/rex/sessions.lua
-- The rex_sessions action in init.lua opens it in a new window.

if rex.block_id == nil then
  error("sessions.lua: run inside a Rex terminal", 0)
end

local home = os.getenv("HOME")
local terminal = "com.superlogical.terminal"

-- The app's client ID differs per server, so take it from this block's owner
-- on the server that runs this script.
local picker = rex.session.describe_block{ block_id = rex.block_id }.block

local function show(session_id, window_id, api, client_id)
  (api or rex).call("client.perform", {
    client_id = client_id or picker.owner,
    action = "session.select",
    origin = "key",
    args = { session_id = session_id, window_id = window_id },
  })
end

-- Show this picker's window. new_window's focus only makes it the session's
-- active window.
show(rex.session_id, picker.window_id)

local function lines(argv)
  local r = rex.exec(argv, { stderr = false })
  local out = {}
  if r ~= nil then
    for line in r.stdout:gmatch("[^\n]+") do
      table.insert(out, line)
    end
  end
  return out
end

local function basename(path)
  return path:match("([^/]+)/*$")
end

local function dirname(path)
  return path:match("^(.*)/[^/]+/*$")
end

-- Candidates: the directories inside ~/personal, ~/.config, ~/opt and each
-- ~/work/*, plus every git project up to two levels below home.
local roots = { home .. "/personal", home .. "/.config", home .. "/opt" }
for _, dir in ipairs(lines{ "find", "-L", home .. "/work", "-mindepth", "1", "-maxdepth", "1", "-type", "d" }) do
  table.insert(roots, dir)
end

local find = { "find", "-L" }
for _, root in ipairs(roots) do
  table.insert(find, root)
end
for _, arg in ipairs{ "-mindepth", "1", "-maxdepth", "1", "-type", "d" } do
  table.insert(find, arg)
end

local candidates = lines(find)
for _, git_dir in ipairs(lines{ "fd", "-H", "-d", "2", "-E", "Library", "-t", "d", "^\\.git$", home }) do
  table.insert(candidates, dirname(git_dir .. "/"))
end

-- Other hosts. Two labels may name the same server, so keep one per endpoint.
local endpoints = {}
local listed = rex.call("hosts.list")
for _, h in ipairs(listed and listed.hosts or {}) do
  endpoints[h.label] = h.endpoints and h.endpoints[1]
end

local remotes, seen = {}, {}
for _, host in ipairs(rex.servers()) do
  local key = endpoints[host] or host
  if not seen[key] then
    seen[key] = true
    remotes[host] = { api = rex.server(host), sessions = {} }
  end
end

-- A host has no call to run a command, but any of its terminals can list a
-- directory. Use one from a session it already has, or from a short-lived
-- session when it has none.
local function remote_candidates(host, remote)
  local api = remote.api
  local list = api.call("session.list")
  if list == nil then return end -- unreachable
  remote.sessions = list.sessions

  local probe = remote.sessions[1] and remote.sessions[1].session_id
  local temporary
  if probe == nil then
    local created = api.call("session.create", {
      initial_windows = { { layout = rex.layout.block{ flavor = terminal .. ".shell" } } },
    })
    if created == nil then return end
    probe, temporary = created.session_id, true
  end
  api.call("session.attach", { session_id = probe })
  local view = api.session.view{ session_id = probe }

  local function subdirs(path)
    local r = api.block.call(terminal, "list_dir", {
      session_id = probe, block_id = view.windows[1].focused_block_id, path = path,
    })
    local out = {}
    for _, e in ipairs(r and r.entries or {}) do
      table.insert(out, { name = e.name, path = r.path .. "/" .. e.name, home = r.home })
    end
    return out
  end

  for _, s in ipairs(remote.sessions) do
    table.insert(candidates, host .. ": session " .. s.label)
  end
  -- Unlike here, every visible directory in home counts as a project:
  -- checking each one for .git costs a call per directory.
  for _, d in ipairs(subdirs("~")) do
    remote.home = d.home
    if d.name:sub(1, 1) ~= "." then table.insert(candidates, host .. ":" .. d.path) end
  end
  local inner = { "~/personal", "~/.config", "~/opt" }
  for _, d in ipairs(subdirs("~/work")) do
    table.insert(inner, d.path)
  end
  for _, root in ipairs(inner) do
    for _, d in ipairs(subdirs(root)) do
      table.insert(candidates, host .. ":" .. d.path)
    end
  end

  if temporary then api.call("session.destroy", { session_id = probe }) end
end

for host, remote in pairs(remotes) do
  local ok, failure = pcall(remote_candidates, host, remote)
  if not ok then rex.log("warn", host .. ": " .. tostring(failure)) end
end

-- fzf reads keys from the terminal and draws on stderr, which rex.exec
-- captures, so send its interface to the terminal.
local pick, err = rex.exec(
  { "sh", "-c", [[exec fzf --layout=reverse --preview-window down --preview 'if [ -d {} ]; then eza --color=always -l {}; else echo {}; fi' 2> /dev/tty]] },
  { stdin = table.concat(candidates, "\n") })
if pick == nil then error(err, 0) end

local selected = pick.stdout:gsub("\n$", "")
if selected == "" then return end

-- Where the selection lives: here, or on the host its prefix names.
local api, client_id, base, label = rex, picker.owner, home, nil
local host, rest = selected:match("^([^/:]+):(.*)$")
if host ~= nil then
  local remote = remotes[host]
  api, base = remote.api, remote.home
  label = rest:match("^ session (.*)$")
  selected = rest

  -- The app on that host: the app client there with this app's label, or
  -- failing that any app client.
  local mine
  for _, c in ipairs(rex.call("client.list").clients) do
    if c.client_id == picker.owner then mine = c.info and c.info.label end
  end
  local match, any
  for _, c in ipairs(api.call("client.list").clients) do
    if c.info and c.info.kind == "app" then
      any = c.client_id
      if c.info.label == mine then match = c.client_id end
    end
  end
  client_id = match or any
  if client_id == nil then error("this app is not connected to " .. host, 0) end
end

-- Name the session after the directory, prefixed with its parent unless the
-- directory sits directly in home.
if label == nil then
  label = basename(selected):gsub("%.", "_")
  local parent = dirname(selected)
  if parent ~= base then
    label = basename(parent):gsub("%.", "_") .. "_" .. label
  end
end

local target
for _, s in ipairs(api.call("session.list").sessions) do
  if s.label == label then target = s.session_id end
end

if target == nil then
  local created, create_err = api.call("session.create", {
    label = label,
    initial_windows = { {
      layout = rex.layout.block{
        flavor = terminal .. ".shell",
        options = { cwd = selected },
      },
    } },
  })
  if created == nil then error(create_err, 0) end
  target = created.session_id
end

api.call("session.attach", { session_id = target })
local view, view_err = api.session.view{ session_id = target }
if view == nil then error(view_err, 0) end

local focused
for _, w in ipairs(view.windows) do
  if w.window_id == view.active_window_id then focused = w.focused_block_id end
end

show(target, view.active_window_id, api, client_id)
api.session.focus_block{ session_id = target, block_id = focused }

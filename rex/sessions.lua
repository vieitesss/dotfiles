-- Native project/session picker. Loaded by init.lua; run with rex do rex_sessions.
--
-- One picker lists every host's sessions and projects: the current host
-- first, then the others by label, each host's sessions before its projects.
-- Titles drop the host's home directory; the host label is the item detail.
--
-- Projects come from a per-host cache in the Rex database, so the picker
-- opens without probing remote hosts. Each open starts a detached
--   rex do sessions.lua --action rex_sessions_refresh
-- that rewrites the cache for the next open. Sessions are always listed live.
local app_client = require("app_client")
local db = require("db")
local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME")
local local_label = "mac"
local cache_key = "sessions_projects"
-- This file, wherever init.lua or rex do loaded it from.
local source = debug.getinfo(1, "S").source:gsub("^@", "")

local function require_result(result, err)
  if result == nil then error(tostring(err), 0) end
  return result
end

-- The environment for rex commands run from the server, whose PATH has no
-- rex. They must not inherit the caller's session, block or client.
local function rex_env()
  local bin = os.getenv("REX_BIN_DIR") or
    home .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS"
  return {
    PATH = bin .. ":" .. home .. "/.local/bin:" .. (os.getenv("PATH") or "/usr/bin:/bin"),
    REX_SESSION = false, REX_BLOCK = false, REX_CLIENT = false,
  }
end

-- rex.call follows ctx.server; rex.exec still runs on the config server.
-- Use its explicit endpoint when an action targets a remote session. Only
-- server RPCs cross this bridge: the picker stays in the native action.
local function config_api(ctx)
  if ctx.server == nil then return rex end
  local endpoint = os.getenv("REX_SERVER")
  if not endpoint or endpoint == "" then error("sessions: config server endpoint unavailable", 0) end
  return { call = function(method, args)
    local argv = { "rex", "--server", endpoint, "--autostart=false", "api", "call", method }
    if args ~= nil then table.insert(argv, rex.json.encode(args)) end
    local result, err = rex.exec(argv, { timeout = 12, env = rex_env() })
    if result == nil then return nil, err end
    if not result.ok then return nil, result.stderr end
    return rex.json.decode(result.stdout)
  end }
end

local function basename(path)
  return path:match("([^/]+)/*$")
end

local function dirname(path)
  return path:match("^(.*)/[^/]+/*$")
end

local function session_label(path, base)
  local label = basename(path):gsub("%.", "_")
  local parent = dirname(path)
  if parent ~= base then label = basename(parent):gsub("%.", "_") .. "_" .. label end
  return label
end

-- path without the leading home directory, or unchanged outside it.
local function relative(path, base)
  if base ~= nil and path:sub(1, #base + 1) == base .. "/" then return path:sub(#base + 2) end
  return path
end

local function lines(argv)
  local result = require_result(rex.exec(argv, { stderr = false }))
  local out = {}
  for line in result.stdout:gmatch("[^\n]+") do table.insert(out, line) end
  return out
end

local function local_projects()
  -- Direct children of the project roots, plus git projects two levels below
  -- home. Use find throughout so discovery needs no interactive shell PATH.
  local paths = {}
  local roots = { home .. "/personal", home .. "/.config", home .. "/opt" }
  for _, dir in ipairs(lines{ "find", "-L", home .. "/work", "-mindepth", "1", "-maxdepth", "1", "-type", "d" }) do
    table.insert(roots, dir)
  end
  local find = { "find", "-L" }
  for _, root in ipairs(roots) do table.insert(find, root) end
  for _, arg in ipairs{ "-mindepth", "1", "-maxdepth", "1", "-type", "d" } do
    table.insert(find, arg)
  end
  for _, path in ipairs(lines(find)) do table.insert(paths, path) end
  for _, path in ipairs(lines{
    "find", home, "-maxdepth", "2", "-path", home .. "/Library", "-prune",
    "-o", "-type", "d", "-name", ".git", "-print",
  }) do
    table.insert(paths, dirname(path))
  end
  return { home = home, paths = paths }
end

local function remote_projects(api)
  local catalog = { paths = {} }
  local sessions = require_result(api.call("session.list")).sessions or {}

  -- Directory listing belongs to a terminal, not the server. An empty host
  -- needs a short-lived probe session, never selected or shown in the app.
  local probe = sessions[1] and sessions[1].session_id
  local temporary = probe == nil
  if temporary then
    probe = require_result(api.call("session.create", {
      initial_windows = { { layout = rex.layout.block{ flavor = terminal .. ".shell" } } },
    })).session_id
  end

  local ok, failure = pcall(function()
    require_result(api.call("session.attach", { session_id = probe }))
    local view = require_result(api.session.view{ session_id = probe })
    local block = view.windows[1].focused_block_id
    local function subdirs(path)
      local result = api.block.call(terminal, "list_dir", {
        session_id = probe, block_id = block, path = path,
      })
      -- Some project roots need not exist on every host.
      if result == nil then return {} end
      catalog.home = result.home or catalog.home
      local dirs = {}
      for _, entry in ipairs(result.entries or {}) do
        table.insert(dirs, { name = entry.name, path = result.path .. "/" .. entry.name })
      end
      return dirs
    end

    -- Every visible home directory counts as a remote project; checking for
    -- .git would cost one round trip per directory.
    for _, dir in ipairs(subdirs("~")) do
      if dir.name:sub(1, 1) ~= "." then table.insert(catalog.paths, dir.path) end
    end
    local roots = { "~/personal", "~/.config", "~/opt" }
    for _, dir in ipairs(subdirs("~/work")) do table.insert(roots, dir.path) end
    for _, root in ipairs(roots) do
      for _, dir in ipairs(subdirs(root)) do table.insert(catalog.paths, dir.path) end
    end
  end)

  if temporary then require_result(api.call("session.destroy", { session_id = probe })) end
  if not ok then error(failure, 0) end
  return catalog
end

-- The local host and every remote host, sorted by label. Aliases of one
-- endpoint become one host under the shortest label. The second result maps
-- any alias to that label.
local function hosts(here)
  local endpoints, labels, aliases = {}, {}, {}
  for _, host in ipairs(require_result(here.call("hosts.list")).hosts or {}) do
    endpoints[host.label] = host.endpoints and host.endpoints[1]
  end
  for _, name in ipairs(rex.servers()) do
    local key = endpoints[name] or name
    aliases[name] = key
    if labels[key] == nil or #name < #labels[key] then labels[key] = name end
  end
  local list = { { label = local_label, api = here } }
  for _, name in pairs(labels) do
    table.insert(list, { label = name, name = name, api = rex.server(name) })
  end
  table.sort(list, function(a, b) return a.label < b.label end)
  return list, function(name) return labels[aliases[name] or name] or name end
end

local function discover(host)
  if host.name == nil then return local_projects() end
  return remote_projects(host.api)
end

-- Rewrite every reachable host's cached projects. A host that fails keeps
-- its previous catalog.
rex.action{
  name = "rex_sessions_refresh",
  title = "Refresh project sessions",
  run = function()
    local found = {}
    for _, host in ipairs((hosts(rex))) do
      local ok, catalog = pcall(discover, host)
      if ok then
        found[host.label] = catalog
      else
        rex.log("warn", "sessions: " .. host.label .. ": " .. tostring(catalog))
      end
    end
    local cache = db.get(cache_key) or {}
    for label, catalog in pairs(found) do cache[label] = catalog end
    db.set(cache_key, cache)
  end,
}

local function start_refresh()
  local argv = { "rex", "--autostart=false" }
  local endpoint = os.getenv("REX_SERVER")
  if endpoint and endpoint ~= "" then
    table.insert(argv, "--server")
    table.insert(argv, endpoint)
  end
  for _, arg in ipairs{ "do", source, "--action", "rex_sessions_refresh" } do table.insert(argv, arg) end
  local ok, err = pcall(rex.exec.start, argv, {
    detach = true, stdout = false, stderr = false, env = rex_env(),
  })
  if not ok then rex.log("warn", "sessions: refresh: " .. tostring(err)) end
end

-- One host's picker entries: sessions first, then projects without a
-- session, each sorted by title. A project with a running session is that
-- session. skip is the session the user is in.
local function host_entries(host, catalog, sessions, skip)
  local by_label = {}
  for _, session in ipairs(sessions) do by_label[session.label] = session end
  local session_entries, project_entries, used, seen = {}, {}, {}, {}
  local function add_session(session, title)
    used[session.session_id] = true
    if session.session_id == skip then return end
    table.insert(session_entries, {
      id = host.label .. ":session:" .. session.session_id, title = title, icon = "terminal",
      candidate = { session_id = session.session_id },
    })
  end
  for _, path in ipairs(catalog.paths or {}) do
    if not seen[path] then
      seen[path] = true
      local session = by_label[session_label(path, catalog.home)]
      if session ~= nil then
        if not used[session.session_id] then add_session(session, relative(path, catalog.home)) end
      else
        table.insert(project_entries, {
          id = host.label .. ":path:" .. path, title = relative(path, catalog.home), icon = "folder",
          candidate = { path = path },
        })
      end
    end
  end
  for _, session in ipairs(sessions) do
    if not used[session.session_id] then add_session(session, session.label) end
  end
  local function by_title(a, b) return a.title < b.title end
  table.sort(session_entries, by_title)
  table.sort(project_entries, by_title)
  for _, entry in ipairs(project_entries) do table.insert(session_entries, entry) end
  return session_entries
end

rex.action{
  name = "rex_sessions",
  title = "Project sessions",
  run = function(ctx)
    -- The catalog belongs to the config server, not the active session's host.
    local here = config_api(ctx)
    local list, canonical = hosts(here)
    local current = ctx.server and canonical(ctx.server) or local_label
    table.sort(list, function(a, b)
      if (a.label == current) ~= (b.label == current) then return a.label == current end
      return a.label < b.label
    end)

    local cache = db.get(cache_key) or {}
    local items, candidates, limited, cached = {}, {}, false, false
    for _, host in ipairs(list) do
      local ok, failure = pcall(function()
        -- A host whose sessions can't be listed is unreachable: hide it,
        -- even when its projects are cached.
        local sessions = require_result(host.api.call("session.list")).sessions or {}
        local catalog = cache[host.label]
        if catalog == nil then
          catalog = discover(host)
          cache[host.label] = catalog
          db.set(cache_key, cache)
        else
          cached = true
        end
        local skip = host.label == current and ctx.session_id or nil
        for _, entry in ipairs(host_entries(host, catalog, sessions, skip)) do
          if #items == 2000 then
            if not limited then rex.log("warn", "sessions: showing only the first 2,000 projects and sessions") end
            limited = true
            return
          end
          entry.candidate.host, entry.candidate.home = host, catalog.home
          candidates[entry.id] = entry.candidate
          table.insert(items, { id = entry.id, title = entry.title, icon = entry.icon, detail = host.label })
        end
      end)
      if not ok then rex.log("warn", "sessions: " .. host.label .. ": " .. tostring(failure)) end
    end
    -- Hosts probed just now are fresh; only a cached catalog needs a refresh.
    if cached then start_refresh() end

    -- UI prompts must run directly inside this config action, outside pcall.
    local selected, why, detail = rex.ui.pick{
      title = "Project sessions",
      placeholder = "Filter projects and sessions",
      items = items,
    }
    if selected == nil then
      if why == "cancelled" then return end
      error("sessions: " .. why .. (detail and ": " .. detail or ""), 0)
    end

    local candidate = candidates[selected]
    local host = candidate.host
    local api, target = host.api, candidate.session_id
    if target == nil then
      local label = session_label(candidate.path, candidate.home)
      local sessions = require_result(api.call("session.list")).sessions or {}
      for _, session in ipairs(sessions) do
        if session.label == label then target = session.session_id; break end
      end
      if target == nil then
        target = require_result(api.call("session.create", {
          label = label,
          initial_windows = { { layout = rex.layout.block{
            flavor = terminal .. ".shell",
            options = { cwd = candidate.path },
          } } },
        })).session_id
      end
    end

    require_result(api.call("session.attach", { session_id = target }))
    local view = require_result(api.call("session.view", { session_id = target }))
    for _, window in ipairs(view.windows or {}) do
      if window.window_id == view.active_window_id and window.focused_block_id then
        require_result(api.call("session.focus_block", { session_id = target, block_id = window.focused_block_id }))
      end
    end
    local args = { session_id = target, window_id = view.active_window_id }
    if host.name == nil then
      -- The app is waiting for this action. Select only after it returns.
      rex.client.queue("session.select", args)
    else
      local client_id = app_client.on(api, here, ctx.client_id)
      if client_id == nil then error("this app is not connected to " .. host.name, 0) end
      require_result(api.call("client.perform", {
        client_id = client_id, action = "session.select", origin = "key", args = args,
      }))
    end
  end,
}

-- Run by tests/rex-sessions.test.sh. Unit cases use a fake API; the shell
-- runner also loads this plugin as a real config action on an isolated server.
package.path = os.getenv("REX_CONFIG_DIR") .. "/?.lua;" .. package.path
local home = os.getenv("HOME")
local json = rex.json
local project = home .. "/personal/demo.app"
local db_path = os.getenv("REX_DB")

local function check(name, got, want)
  if got ~= want then
    error(name .. ": got " .. tostring(got) .. ", want " .. tostring(want), 0)
  end
end

local function run(options)
  local result = { shown = {}, created = {}, focused = {}, warnings = {}, destroyed = {}, started = {}, discovered = 0 }
  local actions = {}
  if not options.cached then os.remove(db_path) end
  local function api(remote)
    local a = {}
    a.call = function(method, args)
      if method == "hosts.list" then
        if remote then return { hosts = {} } end
        return { hosts = {
          { label = "rpi", endpoints = { "https://rpi" } },
          { label = "alias", endpoints = { "https://rpi" } },
        } }
      elseif method == "session.list" then
        if remote and options.unreachable then return nil, "connection refused" end
        return { sessions = remote and (options.empty_remote and {} or {
          { session_id = "remote-session", label = "remote-project" },
        }) or (options.existing and {
          { session_id = "existing-session", label = "personal_demo_app" },
        } or {}) }
      elseif method == "session.create" then
        if options.create_error then return nil, "creation refused" end
        table.insert(result.created, { remote = remote, args = args })
        return { session_id = args.label and "new-session" or "probe-session" }
      elseif method == "session.destroy" then
        table.insert(result.destroyed, args.session_id)
        return {}
      elseif method == "session.attach" then
        return {}
      elseif method == "session.view" then
        return a.session.view(args)
      elseif method == "session.focus_block" then
        return a.session.focus_block(args)
      elseif method == "client.list" then
        local clients = { {
          client_id = remote and "remote-app" or "local-app",
          info = { kind = "app", label = "my-mac" },
        } }
        if remote then
          table.insert(clients, { client_id = "other-app", info = { kind = "app", label = "other-mac" } })
        end
        return { clients = clients }
      elseif method == "client.perform" then
        table.insert(result.shown, { remote = remote, args = args, method = "perform" })
        return {}
      end
      error("unexpected method: " .. method, 0)
    end
    a.session = {
      view = function(args)
        if options.probe_error and args.session_id == "probe-session" then return nil, "probe failed" end
        return { active_window_id = "target-window", windows = { {
          window_id = "target-window", focused_block_id = "target-block",
        } } }
      end,
      focus_block = function(args)
        table.insert(result.focused, { remote = remote, args = args })
        return {}
      end,
    }
    a.block = { call = function(_, _, args)
      return { path = "/home/pi", home = "/home/pi", entries = args.path == "~" and {
        { name = "project" }, { name = ".hidden" },
      } or {} }
    end }
    return a
  end

  local controller = api(false)
  local fake = api(options.server ~= nil)
  fake.json = json
  fake.servers = function()
    return (options.remote or options.server) and (options.alias and { "rpi", "alias" } or { "rpi" }) or {}
  end
  fake.server = function()
    return api(true)
  end
  fake.layout = { block = function(layout) return layout end }
  local function exec(_, argv)
    -- Non-rex commands are the project discovery; rex commands are the
    -- bridge to the config server, routed to the same fake API.
    if argv[1] ~= "rex" then
      result.discovered = result.discovered + 1
      if argv[2] == home then return { stdout = project .. "/.git\n" } end
      if argv[3] == home .. "/work" then return { stdout = "" } end
      if options.many then
        local paths = {}
        for i = 1, 2001 do paths[i] = home .. "/personal/project-" .. i end
        return { stdout = table.concat(paths, "\n") }
      end
      return { stdout = project .. "\n" .. project .. "\n" }
    end
    if options.bridge_error then return nil, "local transport unavailable" end
    local value, err = controller.call(argv[7], argv[8] and json.decode(argv[8]))
    return { ok = value ~= nil, stdout = value and json.encode(value) or "", stderr = err or "" }
  end
  fake.exec = setmetatable({ start = function(argv, opts)
    table.insert(result.started, { argv = argv, opts = opts })
  end }, { __call = exec })
  fake.log = function(_, message) table.insert(result.warnings, message) end
  fake.ui = { pick = function(prompt)
    result.prompt = prompt
    return options.selected, options.why or "cancelled", options.detail
  end }
  fake.client = { queue = function(name, args)
    table.insert(result.shown, { remote = false, method = name, args = { args = args } })
  end }
  fake.action = function(definition)
    actions[definition.name] = definition.run
  end

  local fake_os = setmetatable({
    getenv = function(key)
      if key == "REX_SERVER" then return "unix:///fake/server.sock" end
      return os.getenv(key)
    end,
  }, { __index = os })
  local chunk = assert(loadfile(os.getenv("REX_CONFIG_DIR") .. "/sessions.lua"))
  setfenv(chunk, setmetatable({ rex = fake, os = fake_os }, { __index = _G }))
  chunk()
  check("loading does not prompt", result.prompt, nil)
  local name = options.action or "rex_sessions"
  result.ok, result.err = pcall(actions[name],
    { client_id = "local-app", server = options.server, session_id = options.session_id })
  return result
end

local function find(items, id)
  for _, item in ipairs(items) do
    if item.id == id then return item end
  end
end

local local_project = "mac:path:" .. project
local existing_session = "mac:session:existing-session"
local existing = run{ selected = existing_session, existing = true }
check("existing succeeds", existing.ok, true)
check("native picker title", existing.prompt.title, "Project sessions")
check("project merged into its session", #existing.prompt.items, 1)
check("merged item is the session", existing.prompt.items[1].id, existing_session)
check("merged item icon", existing.prompt.items[1].icon, "terminal")
check("home omitted from title", existing.prompt.items[1].title, "personal/demo.app")
check("host in detail", existing.prompt.items[1].detail, "mac")
check("existing session reused", #existing.created, 0)
check("target session", existing.shown[1].args.args.session_id, "existing-session")
check("local selection waits until action returns", existing.shown[1].method, "session.select")
check("target focus", existing.focused[1].args.block_id, "target-block")

local inside = run{ existing = true, session_id = "existing-session" }
check("current session hidden", #inside.prompt.items, 0)

local created = run{ selected = local_project }
check("creation succeeds", created.ok, true)
check("uncached catalog probed now", created.discovered > 0, true)
check("fresh catalog needs no refresh", #created.started, 0)
check("one session created", #created.created, 1)
check("session label", created.created[1].args.label, "personal_demo_app")
check("session directory", created.created[1].args.initial_windows[1].layout.options.cwd, project)

local cached = run{ cached = true }
check("cached catalog skips discovery", cached.discovered, 0)
check("cached catalog listed", cached.prompt.items[1].id, local_project)
check("cached catalog starts a refresh", #cached.started, 1)
check("refresh is detached", cached.started[1].opts.detach, true)
check("refresh action", cached.started[1].argv[#cached.started[1].argv], "rex_sessions_refresh")

local refused = run{ selected = local_project, create_error = true }
check("creation failure propagates", refused.ok, false)
check("creation failure message", refused.err, "creation refused")
check("failed creation does not switch", #refused.shown, 0)

local cancelled = run{}
check("cancel succeeds", cancelled.ok, true)
check("cancel does not create sessions", #cancelled.created, 0)
check("cancel does not switch sessions", #cancelled.shown, 0)
check("cancel does not focus a target", #cancelled.focused, 0)

for _, reason in ipairs{ "timeout", "no_client", "unsupported", "busy", "failed" } do
  local failure = run{ why = reason, detail = reason == "failed" and "prompt failed" or nil }
  check(reason .. " fails", failure.ok, false)
  check(reason .. " error", failure.err,
    "sessions: " .. reason .. (reason == "failed" and ": prompt failed" or ""))
  check(reason .. " does not create sessions", #failure.created, 0)
end

local remote = run{ selected = "rpi:session:remote-session", remote = true, alias = true }
check("remote session succeeds", remote.ok, true)
check("remote session reused", #remote.created, 0)
check("remote client", remote.shown[1].args.client_id, "remote-app")
check("remote target", remote.shown[1].args.args.session_id, "remote-session")
check("remote selection uses remote API", remote.shown[1].remote, true)
check("remote focus uses remote API", remote.focused[1].remote, true)
check("alias deduplicated and hidden directories excluded", #remote.prompt.items, 3)
check("current host first", remote.prompt.items[1].detail, "mac")
check("shortest alias labels the host", remote.prompt.items[2].detail, "rpi")
check("sessions before projects", remote.prompt.items[2].id, "rpi:session:remote-session")
check("remote home omitted from title", find(remote.prompt.items, "rpi:path:/home/pi/project").title, "project")

local from_rpi = run{ server = "rpi", alias = true }
check("remote current host succeeds", from_rpi.ok, true)
check("remote current host first", from_rpi.prompt.items[1].detail, "rpi")
check("other hosts follow", from_rpi.prompt.items[3].detail, "mac")
local from_alias = run{ server = "alias", alias = true }
check("alias context succeeds", from_alias.ok, true)
check("alias context resolves to its host", from_alias.prompt.items[1].detail, "rpi")

local unreachable = run{ remote = true, unreachable = true }
check("unreachable host hidden", #unreachable.prompt.items, 1)
check("unreachable host reported", #unreachable.warnings, 1)
local cached_unreachable = run{ remote = true }
cached_unreachable = run{ remote = true, unreachable = true, cached = true }
check("unreachable host hidden despite cache", #cached_unreachable.prompt.items, 1)

local remote_context = run{ selected = local_project, server = "rpi", alias = true }
check("local project succeeds from remote context", remote_context.ok, true)
check("local project remains visible", find(remote_context.prompt.items, local_project) ~= nil, true)
check("local creation stays on config server", remote_context.created[1].remote, false)
check("local creation keeps local cwd",
  remote_context.created[1].args.initial_windows[1].layout.options.cwd, project)
check("local focus stays on config server", remote_context.focused[1].remote, false)
check("local switch stays deferred", remote_context.shown[1].method, "session.select")
check("local switch target", remote_context.shown[1].args.args.session_id, "new-session")

local unavailable = run{ selected = local_project, server = "rpi", bridge_error = true }
check("local bridge failure propagates", unavailable.ok, false)
check("local bridge failure message", unavailable.err, "local transport unavailable")
check("failed bridge does not switch", #unavailable.shown, 0)
check("failed bridge never creates on active remote host", #unavailable.created, 0)

local remote_project = run{ selected = "rpi:path:/home/pi/project", remote = true, alias = true }
check("remote project succeeds", remote_project.ok, true)
check("remote creation uses remote API", remote_project.created[1].remote, true)
check("remote home omitted from label", remote_project.created[1].args.label, "project")
check("remote project directory", remote_project.created[1].args.initial_windows[1].layout.options.cwd,
  "/home/pi/project")

local probe = run{ remote = true, empty_remote = true, probe_error = true }
check("temporary probe cleaned up after failure", probe.destroyed[1], "probe-session")
check("probe failure reported", #probe.warnings, 1)
check("probe never shown", #probe.shown, 0)

local many = run{ many = true }
check("item limit", #many.prompt.items, 2000)
check("item limit warning", #many.warnings, 1)

local refreshed = run{ action = "rex_sessions_refresh", remote = true, alias = true }
check("refresh succeeds", refreshed.ok, true)
local stored = json.decode(io.open(db_path):read("*a")).sessions_projects
check("refresh stores local projects", stored.mac.paths[1], project)
check("refresh stores remote projects", stored.rpi.paths[1], "/home/pi/project")
check("refresh stores remote home", stored.rpi.home, "/home/pi")
local kept = run{ action = "rex_sessions_refresh", remote = true, probe_error = true, empty_remote = true, cached = true }
check("refresh survives a failing host", kept.ok, true)
stored = json.decode(io.open(db_path):read("*a")).sessions_projects
check("failing host keeps its catalog", stored.rpi.paths[1], "/home/pi/project")

print("ok")

-- Rex keybindings ported from tmux/.tmux.conf. The tmux prefix (C-Space)
-- becomes the first key of each sequence.

local app_client = require("app_client")
local last_session = require("last_session")

local prefix = "ctrl+space>"
local terminal = "com.superlogical.terminal"

local function bind(key, action, args)
	rex.bind(prefix .. key, action, args)
end

-- Press the prefix twice to send it to the terminal (nested tmux, editors)
bind("ctrl+space", "pane.send_key", { key = "ctrl+space" })

-- Reload config
bind("r", "client.config.reload")

-- rexai Dashboard (tmux: prefix d), by running the rexai shim. The key is
-- handled on the server, whose PATH has no rex, so name the Rex bin directory
-- for the shim and call the shim by absolute path.
rex.bind(prefix .. "d", function(ctx)
	rex.exec({ (os.getenv("HOME") or "") .. "/.local/bin/rexai" }, {
		env = {
			PATH = "/Users/vieitesprefapp/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin",
		},
	})
	return true
end)

-- Panes & Windows
bind("shift+-", "pane.split", { direction = "right" }) -- _
bind("-", "pane.split", { direction = "down" })
bind("c", "client.tab.new")

-- Move between tabs
bind(",", "client.tab.previous")
bind(".", "client.tab.next")

-- Go to tab N with Ctrl+Alt+N (plain Alt+1/2/3 type | @ # on a Spanish layout)
for n = 1, 9 do
	rex.bind("ctrl+alt+" .. n, "client.tab.goto", { index = n })
end

-- Move between panes
bind("h", "pane.focus", { direction = "left" })
bind("j", "pane.focus", { direction = "down" })
bind("k", "pane.focus", { direction = "up" })
bind("l", "pane.focus", { direction = "right" })

-- Resize panes (amount is a percentage of the split)
bind("shift+h", "pane.resize", { direction = "left" })
bind("shift+j", "pane.resize", { direction = "down" })
bind("shift+k", "pane.resize", { direction = "up" })
bind("shift+l", "pane.resize", { direction = "right" })

-- Maximize pane
bind("m", "pane.zoom")

-- Floating shell in the focused pane's directory, like tmux display-popup
rex.action{
	name  = "popup_shell",
	title = "Open Popup Shell",
	run   = function(ctx, args)
		local window_id, cwd
		if ctx.block_id then
			local block = rex.session.describe_block{ block_id = ctx.block_id }
			window_id = block and block.block.window_id
			local proc = rex.block.call(terminal, "process", { block_id = ctx.block_id })
			cwd = proc and proc.foreground and proc.foreground.cwd
		end
		local layer, err = rex.session.new_layer{
			window_id = window_id,
			bounds    = { 0.1, 0.1, 0.8, 0.8 },
			focus     = true,
			layout    = rex.layout.block{
				flavor  = terminal .. ".shell",
				options = { cwd = cwd },
			},
		}
		if err ~= nil then error(err, 0) end

		-- Floating layers have no background of their own, so the panes
		-- behind show through. Give the popup an opaque Merino background.
		local style = rex.exec({ "defaults", "read", "-g", "AppleInterfaceStyle" })
		local dark = style and style.stdout:find("Dark") ~= nil
		rex.block.call(terminal, "set_theme", {
			block_id   = layer.block_ids[1],
			background = dark and "#0d1117" or "#ffffff",
			foreground = dark and "#e6edf3" or "#1f2328",
		})
	end,
}
bind("p", "popup_shell")

-- macOS Option composes characters (alt+a -> å); forward Alt+letter to the
-- terminal as Alt so TUIs like paseito get their alt bindings.
for _, k in ipairs({ "a", "e", "m", "o", "p" }) do
	rex.bind("alt+" .. k, "pane.send_key", { key = "alt+" .. k })
end
-- >>> nexo >>>
local nexo_terminal = "com.superlogical.terminal"

-- Runs inside the new window, on the server that owns the session, which is
-- not this one when the app is attached to a remote host. That server's
-- client ID for the app is the block's owner, so the select goes there and
-- nexo gets it as REX_CLIENT; ctx.client_id is only valid on this server.
local nexo_wrapper = [=[
rex="${REX_BIN_DIR:+$REX_BIN_DIR/}rex"
REX_CLIENT=$("$rex" do - 2>/dev/null <<'LUA'
local b = rex.session.describe_block{ block_id = rex.block_id }.block
rex.call("client.perform", { client_id = b.owner, action = "session.select", origin = "key",
  args = { session_id = rex.session_id, window_id = b.window_id } })
print(b.owner)
LUA
)
export REX_CLIENT
exec "$HOME/.local/bin/nexo" --backend=rex tui "$@"
]=]

-- nexo opens in a new window of this session and closes it when the TUI exits.
local function nexo_launch(ctx, args, label)
  local argv = { "/bin/sh", "-c", nexo_wrapper, "nexo" }
  for _, arg in ipairs(args) do
    table.insert(argv, arg)
  end
  local window, err = rex.session.new_window{
    session_id = ctx.session_id,
    window_label = label,
    focus = true,
    layout = rex.layout.block{
      flavor = nexo_terminal .. ".shell",
      options = {
        command = argv,
        login = false,
        shell = "none",
        exit = { on_completion = true, quick_exit_threshold_ms = 0 },
      },
    },
  }
  if err ~= nil then error(err, 0) end
  return window
end

rex.action({
  name = "nexo_projects",
  title = "nexo projects",
  run = function(ctx)
    return nexo_launch(ctx, { "projects" }, "nexo projects")
  end,
})

rex.action({
  name = "nexo_agents",
  title = "nexo agents",
  run = function(ctx)
    return nexo_launch(ctx, { "agents" }, "nexo agents")
  end,
})
-- <<< nexo <<<

-- nexo agents TUI, opened in a new tab of this session (tmux: prefix a)
bind("a", "nexo_agents")

-- Project session picker in the native palette (tmux: prefix o).
require("sessions")
bind("o", "rex_sessions")

-- Resume pi panes on the session file they have open after the server
-- restarts. pi/agent/extensions/program-resume.ts reports the command; this
-- rule is what lets Rex trust it. The kept flags are the ones that shape the
-- run; every flag that picks a session or adds a prompt is dropped.
rex.set("resume.trust.pi", {
	command = { "pi", "--session", rex.match.under(os.getenv("HOME") .. "/.pi/agent/sessions") },
	flags = {
		["--provider"] = { "keep", values = 1 },
		["--model"] = { "keep", values = 1 },
		["--models"] = { "keep", values = 1 },
		["--thinking"] = { "keep", values = 1 },
		["--tools"] = { "keep", values = 1 },
		["-t"] = { "keep", values = 1 },
		["--exclude-tools"] = { "keep", values = 1 },
		["-xt"] = { "keep", values = 1 },
		["--no-tools"] = "keep",
		["-nt"] = "keep",
		["--no-builtin-tools"] = "keep",
		["-nbt"] = "keep",
		["--extension"] = { "keep", values = 1 },
		["-e"] = { "keep", values = 1 },
		["--no-extensions"] = "keep",
		["-ne"] = "keep",
		["--system-prompt"] = { "keep", values = 1 },
		["--append-system-prompt"] = { "keep", values = 1 },
		["--skill"] = { "keep", values = 1 },
		["--prompt-template"] = { "keep", values = 1 },
		["--theme"] = { "keep", values = 1 },
		["--use-theme"] = { "keep", values = 1 },
		["--tui-mode"] = { "keep", values = 1 },
		["--no-skills"] = "keep",
		["-ns"] = "keep",
		["--no-prompt-templates"] = "keep",
		["-np"] = "keep",
		["--no-themes"] = "keep",
		["--no-context-files"] = "keep",
		["-nc"] = "keep",
		["--no-mcp"] = "keep",
		["--approve"] = "keep",
		["-a"] = "keep",
		["--no-approve"] = "keep",
		["-na"] = "keep",
		["--offline"] = "keep",
		["--verbose"] = "keep",
		-- Session-picking and naming flags: the resumed run already has its
		-- session file, so a pane started with one of these is still resumed.
		["-c"] = "drop",
		["--continue"] = "drop",
		["-r"] = "drop",
		["--resume"] = "drop",
		["--session"] = { "drop", values = 1 },
		["--session-id"] = { "drop", values = 1 },
		["--fork"] = { "drop", values = 1 },
		["-n"] = { "drop", values = 1 },
		["--name"] = { "drop", values = 1 },
	},
})

-- Keep last_session_watch.lua running, to record each session the app shows.
-- It starts on every load of this file, and a new one makes the old one stop.
-- The server's PATH has no rex: see the rexai binding above.
rex.exec.start({ "/bin/sh", "-c",
  'exec "${REX_BIN_DIR:+$REX_BIN_DIR/}rex" do --all "${XDG_CONFIG_HOME:-$HOME/.config}/rex/last_session_watch.lua"' }, {
  detach = true,
  stdout = false,
  stderr = false,
  env = {
    PATH = "/Users/vieitesprefapp/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin",
  },
})

-- Expose this server's DB record to last_session on other servers.
rex.action({
  name = "last_session_state",
  title = "Last session record",
  run = function() return last_session.state() end,
})

-- Require the target session on the server api reaches. A server that
-- cannot answer fails the action.
local function require_session(api, session_id, server_name)
  local list, err = api.call("session.list")
  if list == nil then error(tostring(err), 0) end
  for _, session in ipairs(list.sessions or {}) do
    if session.session_id == session_id then return end
  end
  error((server_name and server_name .. ": " or "") .. "the previous session no longer exists", 0)
end

-- Go back to the session shown before this one (tmux: switch-client -l).
-- Merge the local DB record with records from the app's other servers;
-- leave out servers that cannot answer.
--
-- ctx.server changes where rex.call and rex.session operate, but not where
-- the DB lives or where rex.client.queue resolves sessions.
rex.action({
  name = "last_session",
  title = "Last session",
  run = function(ctx)
    local states = { last_session.state() }
    for _, name in ipairs(rex.servers()) do
      local answer, err = rex.server(name).call("client.action", { action = "last_session_state" })
      local state = answer and answer.result
      if type(state) == "table" then
        state.server = name
        table.insert(states, state)
      else
        rex.log("warn", "last_session: " .. name .. ": " .. tostring(err))
      end
    end

    local target, target_state = last_session.target(ctx.session_id, states)
    if target == nil then error("no previous session recorded", 0) end
    local target_server = target_state.server
    local where = target_server or "this server"

    -- Local target: queue selection until this action returns; the app
    -- resolves session.select on the server receiving it, and queue stays
    -- on this server even when ctx.server is set. client.perform would
    -- wait on the app that is waiting for this action. With a remote key,
    -- rex.call reaches ctx.server, so this server's sessions cannot be
    -- listed; a deleted target then fails in the app instead.
    if target_server == nil then
      if ctx.server == nil then require_session(rex, target.session_id) end
      rex.client.queue("session.select", { session_id = target.session_id })
      return
    end

    -- Remote target: use its named server even when it is ctx.server.
    local api = rex.server(target_server)
    require_session(api, target.session_id, target_server)
    local client_id = app_client.on(api, rex, ctx.client_id)
    if client_id == nil then error(where .. ": this app is not connected", 0) end
    local _, err = api.call("client.perform", {
      client_id = client_id,
      action = "session.select",
      origin = "key",
      args = { session_id = target.session_id },
    })
    if err ~= nil then error(where .. ": " .. tostring(err), 0) end
  end,
})
bind("tab", "last_session")

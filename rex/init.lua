-- Rex keybindings ported from tmux/.tmux.conf. The tmux prefix (C-Space)
-- becomes the first key of each sequence.

local prefix = "ctrl+space>"
local terminal = "com.superlogical.terminal"

local function bind(key, action, args)
	rex.bind(prefix .. key, action, args)
end

-- Press the prefix twice to send it to the terminal (nested tmux, editors)
bind("ctrl+space", "pane.send_key", { key = "ctrl+space" })

-- Reload config
bind("r", "client.config.reload")

-- Panes & Windows
bind("shift+-", "pane.split", { direction = "right" }) -- _
bind("-", "pane.split", { direction = "down" })
bind("c", "client.tab.new")

-- Move between tabs
bind(",", "client.tab.previous")
bind(".", "client.tab.next")

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
local nexo_bin = "/Users/vieitesprefapp/.local/bin/nexo"
local nexo_terminal = "com.superlogical.terminal"

-- nexo opens in a new window of this session and closes it when the TUI exits.
local function nexo_launch(ctx, args, label)
  local argv = { "/usr/bin/env", "REX_CLIENT=" .. tostring(ctx.client_id or ""), nexo_bin, "--backend=rex", "tui" }
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
  -- The app keeps its own visible tab; ask it to show the new window.
  rex.client.queue("session.select", { session_id = ctx.session_id, window_id = window.window_id })
  return window
end

rex.action({
  name = "nexo_tui",
  title = "nexo TUI",
  run = function(ctx)
    return nexo_launch(ctx, {}, "nexo")
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

-- nexo TUI, opened in a new tab of this session (tmux: prefix o / prefix a)
bind("o", "nexo_tui")
bind("a", "nexo_agents")

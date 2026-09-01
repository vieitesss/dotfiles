---@diagnostic disable: undefined-global

local osascript = require("hs.osascript")
local top_padding = 40

local center_tall = function()
	local win = hs.window.focusedWindow()
	local f = win:frame()
	local screen = win:screen()
	local max = screen:frame()

	f.w = 3 * max.w / 5
	f.h = max.h - top_padding
	win:setFrame(f)
	win:centerOnScreen()
	f = win:frame()
	f.y = f.y + 10
	win:setFrame(f)
end

local center_window = function(win)
	if not win then
		return
	end
	local f = win:frame()
	local screen = win:screen()
	local max = screen:frame()

	f.w = 3 * max.w / 5
	f.h = max.h / 1.5
	win:setFrame(f)
	win:centerOnScreen()
end

local center = function()
	center_window(hs.window.focusedWindow())
end

-- Visor style: anchor to the top edge of the window's screen and slide down
-- into place, as if dropping from the top of the screen.
local top_drop_window = function(win)
	if not win then
		return
	end
	local max = win:screen():frame()
	local f = win:frame()

	f.w = 3 * max.w / 5
	f.h = max.h / 2.5
	f.x = max.x + (max.w - f.w) / 2

	local final_y = max.y
	f.y = max.y - f.h
	win:setFrame(f)
	f.y = final_y
	win:setFrame(f, 0.05)
end

hs.hotkey.bind({ "alt", "shift" }, "G", function()
	center_tall()
end)

hs.hotkey.bind({ "alt", "shift" }, "C", function()
	center()
end)

hs.hotkey.bind({ "alt", "ctrl", "shift" }, "R", function()
	hs.reload()
end)

hs.hotkey.bind({ "alt", "shift" }, "D", function()
	hs.task.new(os.getenv("HOME") .. "/.local/bin/system-appearance", nil, { "toggle" }):start()
end)

-- Ask-AI: open a fresh Ghostty window running a vanilla pi scratch session,
-- or continue the most recent one. Ghostty's AppleScript API creates the
-- window in its existing process, while still starting the command in a new
-- window (and a fresh session unless resuming). The window takes a moment to appear, so poll for
-- the newly created one and drop it in from the top once it exists.
local ghostty_windows = function()
	local wins = {}
	for _, w in ipairs(hs.window.allWindows()) do
		local app = w:application()
		if app and app:name() == "Ghostty" then
			table.insert(wins, w)
		end
	end
	return wins
end

local applescript_escape = function(value)
	return value:gsub("\\\\", "\\\\\\\\"):gsub('"', "\\\"")
end

local open_ask_ai = function(script_args)
	local before = {}
	for _, w in ipairs(ghostty_windows()) do
		before[w:id()] = true
	end

	local home = os.getenv("HOME")
	local command = home .. "/.local/bin/ask-ai"
	for _, arg in ipairs(script_args) do
		command = command .. " " .. arg
	end

	local apple_script = [[
 tell application "Ghostty"
     set config to new surface configuration
     set command of config to "]] .. applescript_escape(command) .. [["
     set initial working directory of config to "]] .. applescript_escape(home .. "/personal/me") .. [["
     set newWindow to new window with configuration config
 end tell
 ]]
	local ok = osascript.applescript(apple_script)
	if not ok then
		local fallback_args = { "-na", "Ghostty.app", "--args", "-e", home .. "/.local/bin/ask-ai" }
		for _, arg in ipairs(script_args) do
			table.insert(fallback_args, arg)
		end
		hs.task.new("/usr/bin/open", nil, fallback_args):start()
	end

	local new_win = nil
	local tries = 0
	hs.timer.waitUntil(function()
		tries = tries + 1
		for _, w in ipairs(ghostty_windows()) do
			if not before[w:id()] then
				new_win = w
				return true
			end
		end
		return tries >= 100
	end, function()
		if new_win then
			new_win:focus()
			top_drop_window(new_win)
		end
	end, 0.05)
end

hs.hotkey.bind({ "alt", "shift" }, "A", function()
	open_ask_ai({})
end)

hs.hotkey.bind({ "alt", "ctrl", "shift" }, "A", function()
	open_ask_ai({ "--resume" })
end)

-- Bind Command + ` (Backtick) to cycle windows of the same app
hs.hotkey.bind({ "alt", "shift" }, "N", function()
	local win = hs.window.focusedWindow()
	if not win then
		return
	end

	local app = win:application()
	local appWindows = app:allWindows()

	-- 1. Filter for standard, visible windows
	local validWindows = {}
	for _, w in ipairs(appWindows) do
		if w:isStandard() and w:isVisible() then
			table.insert(validWindows, w)
		end
	end

	if #validWindows < 2 then
		return
	end

	-- 2. SORT the windows by ID to ensure a stable loop order
	table.sort(validWindows, function(a, b)
		return a:id() < b:id()
	end)

	-- 3. Find current index in the sorted list
	local currentIndex = 0
	for i, w in ipairs(validWindows) do
		if w:id() == win:id() then
			currentIndex = i
			break
		end
	end

	-- 4. Calculate next index and focus
	local nextIndex = (currentIndex % #validWindows) + 1
	validWindows[nextIndex]:focus()
end)

require("keyboard-layout")

hs.alert.show("Config loaded")

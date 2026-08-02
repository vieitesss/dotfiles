--[[
  Switch keyboard layout based on whether an external (USB) keyboard is
  connected.

  No external keyboard plugged in -> "Real Spanish" (the built-in MacBook
  layout used for the ISO Spanish keyboard).
  External keyboard plugged in     -> "Spanish" (the standard external
  Spanish layout).

  Edit EXTERNAL_KEYWORDS if your keyboard's USB product name does not
  normally contain the word "keyboard" (e.g. "Keychron", "NuPhy" ...).
  Bluetooth keyboards are not detected by hs.usb; see comment below.
--]]

local usb = require "hs.usb"
local keycodes = require "hs.keycodes"
local timer = require "hs.timer"

local LOCAL_LAYOUT = "Real Spanish"

-- ponytail: external keyboard detected by USB product-name keywords;
-- add your device's name here if it is not detected (e.g. "Keychron").
local EXTERNAL_KEYWORDS = { "keyboard" }

-- Ignore the MacBook's own internal keyboard/touchpad if it shows up as a
-- USB device.
local IGNORE_PATTERNS = { "internal", "trackpad" }

local function lower(s)
	return (s or ""):lower()
end

local function is_external_keyboard(device)
	local name = lower(device.productName or "")

	for _, pattern in ipairs(IGNORE_PATTERNS) do
		if name:find(pattern, 1, true) then
			return false
		end
	end

	for _, keyword in ipairs(EXTERNAL_KEYWORDS) do
		if name:find(keyword, 1, true) then
			return true
		end
	end

	return false
end

local function any_external_keyboard_connected()
	local devices = usb.attachedDevices() or {}

	for _, device in ipairs(devices) do
		if is_external_keyboard(device) then
			return true
		end
	end

	return false
end

local function external_layout_name()
	for _, layout in ipairs(keycodes.layouts() or {}) do
		local l = lower(layout)
		if l:find("spanish", 1, true) and not l:find("real", 1, true) then
			return layout
		end
	end

	return "Spanish"
end

local function apply_layout()
	local external_connected = any_external_keyboard_connected()
	local desired = external_connected and external_layout_name() or LOCAL_LAYOUT
	local current = keycodes.currentLayout()

	if current ~= desired then
		keycodes.setLayout(desired)
	end
end

-- Run on startup and whenever a USB device is added or removed.
usb.watcher.new(apply_layout):start()

-- Polling fallback. This also helps with Bluetooth keyboards, which do not
-- trigger hs.usb events; if you only use USB keyboards you can remove this.
-- timer.doEvery(5, apply_layout)

-- Apply once after Hammerspoon has finished loading.
timer.doAfter(1, apply_layout)

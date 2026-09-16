--[[
  Switch keyboard layout based on whether the ZSA Voyager (external USB
  keyboard) is connected.

  Voyager unplugged -> "Real Spanish" (the built-in MacBook layout used for
  the ISO Spanish keyboard).
  Voyager plugged in -> "Spanish" (the standard external Spanish layout).

  Detection matches the Voyager's USB product name and ZSA vendor ID
  instead of any device whose name contains "keyboard".
  Bluetooth keyboards are not detected by hs.usb; the periodic re-check
  recovers from anything hs.usb misses.
--]]

local usb = require("hs.usb")
local keycodes = require("hs.keycodes")
local timer = require("hs.timer")

local LOCAL_LAYOUT = "Real Spanish"
local EXTERNAL_LAYOUT = "Spanish"
local ZSA_VENDOR_ID = 0x3297
local VOYAGER_PRODUCT_NAME = "voyager"

local function lower(s)
	return (s or ""):lower()
end

local function is_voyager(device)
	return device.vendorID == ZSA_VENDOR_ID
		or lower(device.productName or ""):find(VOYAGER_PRODUCT_NAME, 1, true) ~= nil
end

local function voyager_connected()
	local devices = usb.attachedDevices() or {}

	for _, device in ipairs(devices) do
		if is_voyager(device) then
			return true
		end
	end

	return false
end

local function apply_layout()
	local desired = voyager_connected() and EXTERNAL_LAYOUT or LOCAL_LAYOUT
	local current = keycodes.currentLayout()

	if current ~= desired and not keycodes.setLayout(desired) then
		print("keyboard-layout: could not switch to '" .. desired .. "'")
	end
end

-- Run on startup and whenever a USB device is added or removed. Applying is
-- deferred so the device list settles: on removal the callback can fire
-- before the unplugged device disappears from hs.usb.attachedDevices().
usb.watcher
	.new(function()
		timer.doAfter(0.5, apply_layout)
	end)
	:start()

-- Re-check periodically so a missed event or manual switch cannot leave the
-- wrong layout stuck.
timer.doEvery(5, apply_layout)

-- Apply once after Hammerspoon has finished loading.
timer.doAfter(1, apply_layout)

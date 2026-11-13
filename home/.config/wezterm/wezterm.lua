local wezterm = require("wezterm")

local config = wezterm.config_builder()

config.color_scheme = "rose-pine-moon"
-- Scan user-installed fonts directly, including fonts supplied through Nix.
config.font_dirs = { wezterm.home_dir .. "/Library/Fonts" }
-- Keep an explicit CJK fallback: Hack does not include Chinese glyphs.
config.font = wezterm.font_with_fallback({
	"Hack Nerd Font",
	{ family = "PingFang SC", weight = "Regular" },
})
config.font_size = 15.0
config.colors = { background = "#232136" } -- Match Pi's rose-pine-moon base.
config.window_background_opacity = 1.0
config.macos_window_background_blur = 0
config.hide_tab_bar_if_only_one_tab = true
config.window_decorations = "RESIZE"

-- Forward Cmd shortcuts to herdr, which owns the tabs and panes.
-- These bindings are global: use them inside herdr.
local function herdr_key(key)
	return wezterm.action.SendString("\x02" .. key)
end

config.keys = {
	{ key = "t", mods = "CMD", action = herdr_key("c") },
	{ key = "d", mods = "CMD", action = herdr_key("%") },
	{ key = "d", mods = "CMD|SHIFT", action = herdr_key('"') },
	{ key = "LeftArrow", mods = "CMD|ALT", action = herdr_key("h") },
	{ key = "DownArrow", mods = "CMD|ALT", action = herdr_key("j") },
	{ key = "UpArrow", mods = "CMD|ALT", action = herdr_key("k") },
	{ key = "RightArrow", mods = "CMD|ALT", action = herdr_key("l") },
	{ key = "[", mods = "CMD|SHIFT", action = herdr_key("p") },
	{ key = "]", mods = "CMD|SHIFT", action = herdr_key("n") },
	-- Also cover layouts that report the shifted bracket characters.
	{ key = "{", mods = "CMD", action = herdr_key("p") },
	{ key = "}", mods = "CMD", action = herdr_key("n") },
	{ key = "{", mods = "CMD|SHIFT", action = herdr_key("p") },
	{ key = "}", mods = "CMD|SHIFT", action = herdr_key("n") },
	{ key = "w", mods = "CMD", action = herdr_key("x") },
	{ key = "Enter", mods = "CMD|SHIFT", action = herdr_key("z") },
}
for index = 1, 9 do
	table.insert(config.keys, { key = tostring(index), mods = "CMD", action = herdr_key(tostring(index)) })
end

-- Dim unfocused windows so the focused one is obvious at a glance.
local UNFOCUSED_FOREGROUND_TEXT_HSB = { hue = 1.0, saturation = 0.25, brightness = 0.45 }

-- get_config_overrides() hands back a copy, so the current value is never the
-- same table we last stored; compare the fields instead of the identity.
local function same_text_hsb(actual, expected)
	if actual == nil or expected == nil then
		return actual == expected
	end
	return actual.hue == expected.hue
		and actual.saturation == expected.saturation
		and actual.brightness == expected.brightness
end

wezterm.on("window-focus-changed", function(window)
	local overrides = window:get_config_overrides() or {}
	local text_hsb
	local opacity = 1.0 -- Replace stale translucent overrides on either focus state.
	if not window:is_focused() then
		text_hsb = UNFOCUSED_FOREGROUND_TEXT_HSB
	end

	-- Only write when one of the two values we own actually changes; a redundant
	-- set_config_overrides() call would trigger another config reload.
	if same_text_hsb(overrides.foreground_text_hsb, text_hsb) and overrides.window_background_opacity == opacity then
		return
	end

	overrides.foreground_text_hsb = text_hsb
	overrides.window_background_opacity = opacity
	window:set_config_overrides(overrides)
end)

return config

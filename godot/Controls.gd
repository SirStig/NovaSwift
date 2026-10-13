# NOVA Swift — Godot input map (keyboard + gamepad).
#
# Every game action is registered here at startup with BOTH its keyboard key and
# its controller binding, so Main.gd only ever asks InputMap actions
# (`Input.is_action_pressed("thrust")`) and never a raw key or button. That's
# what makes the Steam Deck (and any SDL-recognised pad — Xbox, PlayStation,
# Switch Pro, 8BitDo) just work: Godot normalises them all to the SDL/Xbox
# layout below, and Steam Input presents the Deck's own controls the same way.
#
# The keyboard defaults are the original's table, exactly as the Apple app ships it
# (KeyBindings.defaults, itself `NovaPrefs_ResetKeyBindings` 0x004b4400): arrows fly,
# Space fires the primary, Control the secondary, Z the afterburner; W / Alt-W step the
# secondary, S clears it; ` or Tab / Shift-` or Shift-Tab / Alt-` cycle ship targets, R takes the nearest
# hostile, Alt-R the nearest ship; N clears the travel selection (Alt-N the ship target),
# 1-4 pick the system's nav stellars; \ / Shift-\ step the armed hyperspace link (raising the
# route mini map, - / = zoom it); Return dismisses the status message; Y hails (Alt-Y the stellar), L lands, M is the map,
# H re-arms the route, J jumps, B boards; P Player Info, I Mission Info; E shows the
# Escort Commands panel (then 1-5 pick a group) and F attack · D defend · V hold ·
# C formation · Alt-C return to hangar order them.
# "Key layout" in Settings -> Controls can switch to the port's earlier layout (the Apple
# app's `modernKeyBindings` enhancement: Return fires secondaries, Shift is the
# afterburner, Tab / R / T / U target, P pauses); the default is the original's.
#
# The pad layout mirrors the Apple app's `PadBindings.defaults`
# (app/NovaSwift/Input/PadBindings.swift) so a player moving between the two
# builds keeps their muscle memory:
#
#   Left stick   turn (x) · thrust up / reverse down
#   Right stick  aim — the ship rotates to face where the stick points
#   RT / LT      thrust / reverse          L3  afterburner
#   A / B        fire primary / secondary  LB/RB  previous / next secondary
#   X / Y        nearest target / nearest hostile
#   R3           clear target
#   D-pad ↓      land         D-pad ↑  hyperjump (J)         Back/Select  galaxy map (M)
#   D-pad ←      hail target  D-pad →  board (B)
#
# 1-5 pick an escort group while the Escort Commands panel is up (otherwise 1-4 select
# nav stellars). Inside the comm window: G greetings, R request assistance, E / Enter /
# Esc close (the original's own shortcuts).
#
# Player Info (P / pause menu) and Mission Info (I): tabs General · Cargo · Extras ·
# Honors · Missions; focus nav moves, A/Enter presses, B/Esc/P/I close. In the
# Mission BBS A (X on the pad) accepts the shown listing, B/Esc leaves.
#
# Galaxy map: left stick moves a cursor that snaps to nearby systems, right
# stick pans, LB/RB zoom, A plot (arm a linked jump), Y add a hop (Shift+click),
# X toggle auto-route (enhancement), L3 find a system, B / Back close.
#
# Docked (screens/Spaceport.gd): d-pad / stick move focus, A press (buy), X sell,
# Y buy-quantity prompt (ship info in the shipyard), RB sell-quantity prompt,
# B back out of a screen (from the landing screen: launch).
#
# Registered at runtime rather than written into project.godot's [input] block
# because the serialised InputEvent form there is unreadable, and a single table
# here is the one place the rebinding screen (screens/Settings.gd) needs to touch:
# it edits `overrides`, Prefs.gd persists them, and register() re-applies.

# Loaded with preload() (not class_name) so it resolves without an editor
# import pass — headless runs and fresh checkouts have no global class cache.
extends RefCounted

# Stick dead zone, matching the Apple app's default "Stick dead zone" (0.15).
# STICK_DEADZONE is the default; `stick_deadzone` is the live setting (Prefs.gd /
# the Settings screen) that register() applies to every stick-driven action.
const STICK_DEADZONE := 0.15
static var stick_deadzone := STICK_DEADZONE
# The right stick only aims once it's pushed past this — same floor the Apple
# app uses, so a resting thumb doesn't fight the turn keys.
const AIM_THRESHOLD := 0.5
# Analog triggers count as "held" past this, as GameControllerInput does (0.1).
const TRIGGER_THRESHOLD := 0.1

# action -> { keys: [Key], alt_keys: [Key] (Alt chords), shift_keys: [Key] (Shift
# chords), buttons: [JoyButton], axes: [[JoyAxis, sign]] }. Godot matches a chord's
# plain key too (extra modifiers are ignored), so the polling code tests the chord
# variant of a pair first (Main.gd `_chord`, Interactions.gd).
const BINDINGS := {
	# Flight (held)
	"turn_left": {"keys": [KEY_LEFT], "axes": [[JOY_AXIS_LEFT_X, -1.0]]},
	"turn_right": {"keys": [KEY_RIGHT], "axes": [[JOY_AXIS_LEFT_X, 1.0]]},
	"thrust": {"keys": [KEY_UP],
		"axes": [[JOY_AXIS_LEFT_Y, -1.0], [JOY_AXIS_TRIGGER_RIGHT, 1.0]]},
	"reverse": {"keys": [KEY_DOWN],
		"axes": [[JOY_AXIS_LEFT_Y, 1.0], [JOY_AXIS_TRIGGER_LEFT, 1.0]]},
	"afterburner": {"keys": [KEY_Z], "buttons": [JOY_BUTTON_LEFT_STICK]},
	"fire_primary": {"keys": [KEY_SPACE], "buttons": [JOY_BUTTON_A]},
	"fire_secondary": {"keys": [KEY_CTRL], "buttons": [JOY_BUTTON_B]},
	# Right-stick aim (analog; read as a vector, never as a button)
	"aim_left": {"axes": [[JOY_AXIS_RIGHT_X, -1.0]]},
	"aim_right": {"axes": [[JOY_AXIS_RIGHT_X, 1.0]]},
	"aim_up": {"axes": [[JOY_AXIS_RIGHT_Y, -1.0]]},
	"aim_down": {"axes": [[JOY_AXIS_RIGHT_Y, 1.0]]},
	# Flight (press once)
	# Tab steps ship targets too (the original manual's "Target" key; the table's DIK 0x29 is `).
	"target_next": {"keys": [KEY_QUOTELEFT, KEY_TAB], "buttons": [JOY_BUTTON_X]},
	"target_prev": {"shift_keys": [KEY_QUOTELEFT, KEY_TAB]},
	"target_escort_next": {"alt_keys": [KEY_QUOTELEFT]},
	"target_nearest": {"alt_keys": [KEY_R]},
	"target_nearest_hostile": {"keys": [KEY_R], "buttons": [JOY_BUTTON_Y]},
	"clear_target": {"keys": [KEY_N], "buttons": [JOY_BUTTON_RIGHT_STICK]},
	# Return dismisses the status-bar message (slot 0x06); \ steps the armed hyperspace link
	# (slot 0x0d, Shift back), raising the route mini map, which - / = zoom (Apple GameAction
	# .dismissMessage / .cycleHyperspaceLink / .routeMapZoomOut / .routeMapZoomIn).
	"dismiss_message": {"keys": [KEY_ENTER, KEY_KP_ENTER]},
	"cycle_hyperspace_link": {"keys": [KEY_BACKSLASH]},
	"cycle_hyperspace_link_prev": {"shift_keys": [KEY_BACKSLASH]},
	"route_map_zoom_out": {"keys": [KEY_MINUS]},
	"route_map_zoom_in": {"keys": [KEY_EQUAL]},
	"clear_ship_target": {"alt_keys": [KEY_N]},
	"nav_stellar_1": {"keys": [KEY_1]},
	"nav_stellar_2": {"keys": [KEY_2]},
	"nav_stellar_3": {"keys": [KEY_3]},
	"nav_stellar_4": {"keys": [KEY_4]},
	"secondary_next": {"keys": [KEY_W], "buttons": [JOY_BUTTON_RIGHT_SHOULDER]},
	"secondary_prev": {"alt_keys": [KEY_W], "buttons": [JOY_BUTTON_LEFT_SHOULDER]},
	"clear_secondary": {"keys": [KEY_S]},
	"land": {"keys": [KEY_L], "buttons": [JOY_BUTTON_DPAD_DOWN]},
	# In-flight interactions (screens/Interactions.gd).
	"hail_target": {"keys": [KEY_Y], "buttons": [JOY_BUTTON_DPAD_LEFT]},
	"hail_stellar": {"alt_keys": [KEY_Y]},
	"board_target": {"keys": [KEY_B], "buttons": [JOY_BUTTON_DPAD_RIGHT]},
	# Ship commands of the original's table (Apple KeyBindings.defaults): U toggles the
	# cloak, Alt-X abandons ship (escape pod / ejectable bay), Alt-− is the self-destruct
	# (held five seconds, released to abort). Fighters are recalled by a key only in the
	# modern layout (G); the original calls them home through the escort orders.
	"toggle_cloak": {"keys": [KEY_U]},
	"eject": {"alt_keys": [KEY_X]},
	"self_destruct": {"alt_keys": [KEY_MINUS]},
	"recall_fighters": {"keys": []},
	"escort_panel": {"keys": [KEY_E]},
	"escort_attack": {"keys": [KEY_F]},
	"escort_defend": {"keys": [KEY_D]},
	"escort_hold": {"keys": [KEY_V]},
	"escort_formation": {"keys": [KEY_C]},
	"escort_return": {"alt_keys": [KEY_C]},
	"escort_group_1": {"keys": [KEY_1]},
	"escort_group_2": {"keys": [KEY_2]},
	"escort_group_3": {"keys": [KEY_3]},
	"escort_group_4": {"keys": [KEY_4]},
	"escort_group_5": {"keys": [KEY_5]},
	# Docked. Row selection uses Godot's built-in ui_up/ui_down (arrows, d-pad,
	# left stick). Launch deliberately isn't the d-pad: ↓ moves the row cursor.
	"trade_sell": {"keys": [KEY_S], "buttons": [JOY_BUTTON_X]},
	"shop_buy_qty": {"keys": [KEY_Q], "buttons": [JOY_BUTTON_Y]},
	"shop_sell_qty": {"keys": [KEY_E], "buttons": [JOY_BUTTON_RIGHT_SHOULDER]},
	"ship_info": {"keys": [KEY_I], "buttons": [JOY_BUTTON_Y]},
	"launch": {"keys": [KEY_L], "buttons": [JOY_BUTTON_B]},
	# Navigation. The original binds the map to M and the hyperdrive to J.
	"galaxy_map": {"keys": [KEY_M], "buttons": [JOY_BUTTON_BACK]},
	"hyperspace_arm": {"keys": [KEY_H]},
	"hyperjump": {"keys": [KEY_J], "buttons": [JOY_BUTTON_DPAD_UP]},
	# Story (screens/StoryScreens.gd, Spaceport.gd). The original binds Player Info
	# to P and Mission Info to I (KeyBindings.defaults); the Apple pad layout has no
	# button for either; pad players reach Player Info from the pause menu.
	"player_info": {"keys": [KEY_P]},
	# In-flight pause menu (screens/PauseMenu.gd). Only Main.gd polls it, and only
	# while flying: map / dialogs / docked screens keep Esc and B for themselves.
	"pause_menu": {"keys": [KEY_ESCAPE], "buttons": [JOY_BUTTON_START]},
	"mission_info": {"keys": [KEY_I]},
	# Mission BBS: the original's `a` accepts the shown listing.
	"bbs_accept": {"keys": [KEY_A], "buttons": [JOY_BUTTON_X]},
	# Galaxy map screen (only polled while it is open)
	"map_cursor_left": {"axes": [[JOY_AXIS_LEFT_X, -1.0]]},
	"map_cursor_right": {"axes": [[JOY_AXIS_LEFT_X, 1.0]]},
	"map_cursor_up": {"axes": [[JOY_AXIS_LEFT_Y, -1.0]]},
	"map_cursor_down": {"axes": [[JOY_AXIS_LEFT_Y, 1.0]]},
	"map_pan_left": {"keys": [KEY_LEFT], "axes": [[JOY_AXIS_RIGHT_X, -1.0]]},
	"map_pan_right": {"keys": [KEY_RIGHT], "axes": [[JOY_AXIS_RIGHT_X, 1.0]]},
	"map_pan_up": {"keys": [KEY_UP], "axes": [[JOY_AXIS_RIGHT_Y, -1.0]]},
	"map_pan_down": {"keys": [KEY_DOWN], "axes": [[JOY_AXIS_RIGHT_Y, 1.0]]},
	"map_zoom_in": {"keys": [KEY_EQUAL, KEY_KP_ADD], "buttons": [JOY_BUTTON_RIGHT_SHOULDER]},
	"map_zoom_out": {"keys": [KEY_MINUS, KEY_KP_SUBTRACT], "buttons": [JOY_BUTTON_LEFT_SHOULDER]},
	"map_select": {"keys": [KEY_ENTER, KEY_KP_ENTER], "buttons": [JOY_BUTTON_A]},
	"map_extend": {"keys": [KEY_TAB], "buttons": [JOY_BUTTON_Y]},
	"map_auto_route": {"keys": [KEY_T], "buttons": [JOY_BUTTON_X]},
	"map_center": {"keys": [KEY_C], "buttons": [JOY_BUTTON_RIGHT_STICK]},
	"map_find": {"keys": [KEY_F], "buttons": [JOY_BUTTON_LEFT_STICK]},
	"map_close": {"keys": [KEY_ESCAPE], "buttons": [JOY_BUTTON_B]},
}


# The key layout in force: "original" (the default — the original's table, above) or
# "modern" (the Apple app's `modernKeyBindings` enhancement layout, MODERN_KEYS below).
# Prefs.gd fills this from [input] layout before register().
const LAYOUT_ORIGINAL := "original"
const LAYOUT_MODERN := "modern"
static var layout := LAYOUT_ORIGINAL

# The port's earlier layout (KeyBindings.modernDefaults): only the actions whose keys
# differ from BINDINGS appear; an empty list unbinds. Return fires secondaries (no
# Control-arrow clash on macOS), Shift is the afterburner, Tab cycles targets, R/T take
# the nearest ship / hostile and U clears the target; P pauses (Player Info and Mission
# Info are menu-driven there). The original's Alt-` / Shift-` / Alt-N / Alt-C extras have
# no key in that layout.
const MODERN_KEYS := {
	"afterburner": {"keys": [KEY_SHIFT]},
	"fire_secondary": {"keys": [KEY_ENTER]},
	"target_next": {"keys": [KEY_TAB]},
	"dismiss_message": {"keys": []},
	"cycle_hyperspace_link": {"keys": []},
	"cycle_hyperspace_link_prev": {"shift_keys": []},
	"route_map_zoom_out": {"keys": []},
	"route_map_zoom_in": {"keys": []},
	"target_prev": {"shift_keys": []},
	"target_escort_next": {"alt_keys": []},
	"target_nearest": {"keys": [KEY_R], "alt_keys": []},
	"target_nearest_hostile": {"keys": [KEY_T]},
	"clear_target": {"keys": [KEY_U]},
	"clear_ship_target": {"alt_keys": []},
	"escort_formation": {"keys": []},
	"escort_return": {"alt_keys": []},
	"toggle_cloak": {"keys": [KEY_C]},
	"recall_fighters": {"keys": [KEY_G]},
	"player_info": {"keys": []},
	"mission_info": {"keys": []},
	"pause_menu": {"keys": [KEY_ESCAPE, KEY_P]},
}


# Player rebinds, action -> { keys?: [Key], buttons?: [JoyButton], alt_keys?: [Key], shift_keys?: [Key] }.
# Only the fields the player changed are present; everything else (including the
# analog axes, which are never rebindable — as with the Apple app's sticks) comes
# from BINDINGS. Prefs.gd fills this from user://settings.cfg before register().
static var overrides := {}

# Rebinding screen layout: group -> actions it lists, in order. A key/button may
# only be held by one action *per group* (the same contexts never overlap in
# play; Q is both "previous weapon" in flight and "buy quantity" when docked).
const GROUPS := {
	"Flight": ["turn_left", "turn_right", "thrust", "reverse", "afterburner", "fire_primary",
		"fire_secondary", "secondary_next", "secondary_prev", "clear_secondary",
		"target_next", "target_prev", "target_escort_next", "target_nearest_hostile", "target_nearest",
		"clear_target", "clear_ship_target", "nav_stellar_1", "nav_stellar_2", "nav_stellar_3",
		"nav_stellar_4", "cycle_hyperspace_link", "cycle_hyperspace_link_prev", "route_map_zoom_out",
		"route_map_zoom_in", "dismiss_message", "land", "galaxy_map", "hyperspace_arm", "hyperjump", "player_info",
		"mission_info", "pause_menu", "hail_target", "hail_stellar", "board_target",
		"escort_panel", "escort_attack", "escort_defend", "escort_hold", "escort_formation",
		"toggle_cloak", "eject", "self_destruct", "recall_fighters",
		"escort_return", "escort_group_1", "escort_group_2", "escort_group_3",
		"escort_group_4", "escort_group_5"],
	"Docked": ["trade_sell", "shop_buy_qty", "shop_sell_qty", "ship_info", "launch", "bbs_accept"],
	"Galaxy map": ["map_pan_left", "map_pan_right", "map_pan_up", "map_pan_down", "map_zoom_in",
		"map_zoom_out", "map_select", "map_extend", "map_auto_route", "map_center", "map_find", "map_close"],
}

const ACTION_LABELS := {
	"turn_left": "Turn left", "turn_right": "Turn right", "thrust": "Thrust", "reverse": "Reverse / brake",
	"afterburner": "Afterburner", "fire_primary": "Fire primary", "fire_secondary": "Fire secondary",
	"target_nearest": "Target nearest ship", "target_nearest_hostile": "Target nearest hostile",
	"target_next": "Next target", "target_prev": "Previous target", "target_escort_next": "Next escort",
	"clear_target": "Clear travel selection", "dismiss_message": "Dismiss message",
	"cycle_hyperspace_link": "Next hyperspace link", "cycle_hyperspace_link_prev": "Previous hyperspace link",
	"route_map_zoom_out": "Route map: zoom out", "route_map_zoom_in": "Route map: zoom in", "clear_ship_target": "Clear ship target",
	"nav_stellar_1": "Nav stellar 1", "nav_stellar_2": "Nav stellar 2", "nav_stellar_3": "Nav stellar 3",
	"nav_stellar_4": "Nav stellar 4", "clear_secondary": "Clear secondary", "hyperspace_arm": "Arm route (hyperspace)",
	"secondary_prev": "Previous secondary", "secondary_next": "Next secondary",
	"land": "Land", "galaxy_map": "Galaxy map", "hyperjump": "Hyperjump", "player_info": "Player info",
	"mission_info": "Mission info", "pause_menu": "Pause menu", "hail_target": "Hail target",
	"hail_stellar": "Hail stellar", "board_target": "Board target", "escort_panel": "Escort commands",
	"escort_attack": "Escorts: attack", "escort_defend": "Escorts: defend", "escort_hold": "Escorts: hold",
	"escort_formation": "Escorts: formation", "escort_return": "Escorts: return to hangar",
	"toggle_cloak": "Toggle cloak", "eject": "Eject (escape pod)", "self_destruct": "Self-destruct (hold)",
	"recall_fighters": "Recall fighters",
	"escort_group_1": "Escort group 1", "escort_group_2": "Escort group 2", "escort_group_3": "Escort group 3",
	"escort_group_4": "Escort group 4", "escort_group_5": "Escort group 5",
	"trade_sell": "Sell", "shop_buy_qty": "Buy quantity", "shop_sell_qty": "Sell quantity",
	"ship_info": "Ship info", "launch": "Launch", "bbs_accept": "Accept mission",
	"map_pan_left": "Pan left", "map_pan_right": "Pan right", "map_pan_up": "Pan up", "map_pan_down": "Pan down",
	"map_zoom_in": "Zoom in", "map_zoom_out": "Zoom out", "map_select": "Plot course", "map_extend": "Add hop",
	"map_auto_route": "Auto-route", "map_center": "Recentre", "map_find": "Find system",
	"map_close": "Close map",
}


## The binding spec in force for `action`: BINDINGS with the player's overrides on top.
static func effective(action: String) -> Dictionary:
	var spec: Dictionary = (BINDINGS[action] as Dictionary).duplicate(true)
	if layout == LAYOUT_MODERN and MODERN_KEYS.has(action):
		for field in MODERN_KEYS[action]:
			spec[field] = (MODERN_KEYS[action][field] as Array).duplicate()
	var o: Dictionary = overrides.get(action, {})
	for field in ["keys", "buttons", "alt_keys", "shift_keys"]:
		if o.has(field):
			spec[field] = (o[field] as Array).duplicate()
	return spec


## Group name an action is listed under ("" for non-rebindable analog-only ones).
static func group_of(action: String) -> String:
	for g in GROUPS:
		if action in GROUPS[g]:
			return g
	return ""


## Rebind `action`'s `field` ("keys" | "alt_keys" | "buttons") to the single
## physical input `code`. A second action in the same group already holding it
## is given this action's old binding (a swap, as PadBindings.bind does) so
## nothing is ever left silently double-bound. Returns the swapped action or "".
static func rebind(action: String, field: String, code: int) -> String:
	var group := group_of(action)
	var old: Array = effective(action).get(field, [])
	var swapped := ""
	for other in GROUPS.get(group, []):
		if other == action:
			continue
		var spec := effective(other)
		if code in spec.get(field, []):
			var o: Dictionary = overrides.get(other, {})
			o[field] = old.duplicate()
			overrides[other] = o
			swapped = other
			break
	var mine: Dictionary = overrides.get(action, {})
	mine[field] = [code]
	overrides[action] = mine
	return swapped


static func reset_defaults() -> void:
	overrides.clear()


## Human-readable binding for the rebind screen, e.g. "Left / A", "Alt+Y", "—".
static func describe_keys(action: String) -> String:
	var spec := effective(action)
	var parts: Array[String] = []
	for k in spec.get("keys", []):
		parts.append(OS.get_keycode_string(k))
	for k in spec.get("alt_keys", []):
		parts.append("Alt+" + OS.get_keycode_string(k))
	for k in spec.get("shift_keys", []):
		parts.append("Shift+" + OS.get_keycode_string(k))
	return " / ".join(parts) if not parts.is_empty() else "—"


const _BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_DOWN: "D-pad down",
	JOY_BUTTON_DPAD_LEFT: "D-pad left", JOY_BUTTON_DPAD_RIGHT: "D-pad right",
}


static func button_name(button: int) -> String:
	return _BUTTON_NAMES.get(button, "Button %d" % button)


static func describe_buttons(action: String) -> String:
	var spec := effective(action)
	var parts: Array[String] = []
	for b in spec.get("buttons", []):
		parts.append(button_name(b))
	# Analog inputs are fixed; name them so the row tells the whole story.
	for axis_pair in spec.get("axes", []):
		match int(axis_pair[0]):
			JOY_AXIS_TRIGGER_RIGHT: parts.append("RT")
			JOY_AXIS_TRIGGER_LEFT: parts.append("LT")
			JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y: parts.append("L-stick")
			JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y: parts.append("R-stick")
	return " / ".join(parts) if not parts.is_empty() else "—"


static func register() -> void:
	for action in BINDINGS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		var trigger_only := true
		var spec: Dictionary = effective(action)
		for axis_pair in spec.get("axes", []):
			if axis_pair[0] != JOY_AXIS_TRIGGER_LEFT and axis_pair[0] != JOY_AXIS_TRIGGER_RIGHT:
				trigger_only = false
		# Per-action dead zone: triggers rest at 0 and need only a light squeeze,
		# sticks need the dead zone to swallow drift.
		InputMap.add_action(action, TRIGGER_THRESHOLD if trigger_only and spec.has("axes") else stick_deadzone)
		for key in spec.get("keys", []):
			var k := InputEventKey.new()
			k.physical_keycode = key
			InputMap.action_add_event(action, k)
		for key in spec.get("alt_keys", []):
			var ak := InputEventKey.new()
			ak.physical_keycode = key
			ak.alt_pressed = true
			InputMap.action_add_event(action, ak)
		for key in spec.get("shift_keys", []):
			var sk := InputEventKey.new()
			sk.physical_keycode = key
			sk.shift_pressed = true
			InputMap.action_add_event(action, sk)
		for button in spec.get("buttons", []):
			var b := InputEventJoypadButton.new()
			b.device = -1   # any connected pad
			b.button_index = button
			InputMap.action_add_event(action, b)
		for axis_pair in spec.get("axes", []):
			var m := InputEventJoypadMotion.new()
			m.device = -1
			m.axis = axis_pair[0]
			m.axis_value = axis_pair[1]
			InputMap.action_add_event(action, m)


## Right-stick aim as an engine compass heading (radians, 0 = up, clockwise), or
## NAN when the stick is resting inside the aim threshold.
static func aim_heading() -> float:
	var v := Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down", 0.0)
	if v.length() < AIM_THRESHOLD:
		return NAN
	# Godot's stick y grows downward; compass heading is atan2(east, north).
	return atan2(v.x, -v.y)


## True when any controller is plugged in — the HUD switches its hints to pad
## glyphs then (Steam Deck always reports its built-in pad).
static func pad_connected() -> bool:
	return not Input.get_connected_joypads().is_empty()

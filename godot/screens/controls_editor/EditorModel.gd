# NOVA Swift — Controls Editor model: the pure (UI-free) queries the editor views share.
#
# The editor is a new *view* over Controls.gd: nothing here owns binding data. It answers
# "which action does key X trigger in group G on layer L?", "which pad button does what?",
# categorises actions (the tint of a keycap / pad control) and holds the picker choices that
# Prefs persists ([input] ctl_preset / ctl_pad_style).
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")

## Modifier layers of the keyboard tab -> the Controls.gd field each edits.
const LAYERS := ["Base", "Shift", "Alt"]
const LAYER_FIELDS := ["keys", "shift_keys", "alt_keys"]

const GROUP_NAMES := ["Flight", "Docked", "Galaxy map"]

## Category id -> [display name, tint]. One fixed colour each, shown in the legend.
const CATEGORIES := {
	"flight": ["Flight", Color(0.30, 0.62, 1.0)],
	"combat": ["Combat", Color(1.0, 0.36, 0.34)],
	"targeting": ["Targeting", Color(1.0, 0.72, 0.25)],
	"navigation": ["Navigation", Color(0.34, 0.84, 0.50)],
	"interface": ["Interface", Color(0.72, 0.52, 1.0)],
	"camera": ["Camera", Color(0.28, 0.82, 0.88)],
}
const CATEGORY_ORDER := ["flight", "combat", "targeting", "navigation", "interface", "camera"]

const _CAT := {
	"flight": ["turn_left", "turn_right", "thrust", "reverse", "afterburner", "toggle_cloak", "eject", "self_destruct"],
	"combat": ["fire_primary", "fire_secondary", "secondary_next", "secondary_prev", "clear_secondary",
		"recall_fighters", "escort_panel", "escort_attack", "escort_defend", "escort_hold", "escort_formation",
		"escort_return", "escort_group_1", "escort_group_2", "escort_group_3", "escort_group_4", "escort_group_5"],
	"targeting": ["target_next", "target_prev", "target_escort_next", "target_nearest", "target_nearest_hostile",
		"clear_target", "clear_ship_target", "hail_target", "hail_stellar", "board_target",
		"nav_stellar_1", "nav_stellar_2", "nav_stellar_3", "nav_stellar_4"],
	"navigation": ["land", "galaxy_map", "hyperspace_arm", "hyperjump", "cycle_hyperspace_link",
		"cycle_hyperspace_link_prev", "launch", "map_select", "map_extend", "map_auto_route", "map_find", "map_close"],
	"interface": ["dismiss_message", "player_info", "mission_info", "pause_menu", "trade_sell", "shop_buy_qty",
		"shop_sell_qty", "ship_info", "bbs_accept"],
	"camera": ["route_map_zoom_out", "route_map_zoom_in", "map_pan_left", "map_pan_right", "map_pan_up",
		"map_pan_down", "map_zoom_in", "map_zoom_out", "map_center"],
}

## Pairs the original never has live at once (nav stellars vs escort groups): not conflicts.
const _CONTEXT_PAIRS := {"nav_stellar_1": "escort_group_1", "nav_stellar_2": "escort_group_2",
	"nav_stellar_3": "escort_group_3", "nav_stellar_4": "escort_group_4"}

static var _cat_of: Dictionary = {}


static func category_of(action: String) -> String:
	if _cat_of.is_empty():
		for c in _CAT:
			for a in _CAT[c]:
				_cat_of[a] = c
	return str(_cat_of.get(action, "interface"))


static func cat_color(action: String) -> Color:
	return CATEGORIES[category_of(action)][1]


static func label_of(action: String) -> String:
	return str(Controls.ACTION_LABELS.get(action, action))


const _SHORT := {
	"turn_left": "Turn L", "turn_right": "Turn R", "thrust": "Thrust", "reverse": "Reverse", "afterburner": "Burner",
	"fire_primary": "Fire", "fire_secondary": "Fire 2nd", "secondary_next": "2nd >", "secondary_prev": "2nd <",
	"clear_secondary": "Clr 2nd", "target_next": "Target", "target_prev": "Target <", "target_escort_next": "Escort",
	"target_nearest": "Nearest", "target_nearest_hostile": "Hostile", "clear_target": "Clr Nav", "clear_ship_target": "Clr Tgt",
	"nav_stellar_1": "Nav 1", "nav_stellar_2": "Nav 2", "nav_stellar_3": "Nav 3", "nav_stellar_4": "Nav 4",
	"cycle_hyperspace_link": "Link >", "cycle_hyperspace_link_prev": "Link <", "route_map_zoom_out": "Map -",
	"route_map_zoom_in": "Map +", "dismiss_message": "Dismiss", "land": "Land", "galaxy_map": "Map", "hyperspace_arm": "Arm",
	"hyperjump": "Jump", "player_info": "Pilot", "mission_info": "Missions", "pause_menu": "Pause", "hail_target": "Hail",
	"hail_stellar": "Hail Pl.", "board_target": "Board", "escort_panel": "Escorts", "escort_attack": "Esc: Atk",
	"escort_defend": "Esc: Def", "escort_hold": "Esc: Hold", "escort_formation": "Esc: Form", "escort_return": "Esc: Home",
	"escort_group_1": "Grp 1", "escort_group_2": "Grp 2", "escort_group_3": "Grp 3", "escort_group_4": "Grp 4",
	"escort_group_5": "Grp 5", "toggle_cloak": "Cloak", "eject": "Eject", "self_destruct": "Destruct",
	"recall_fighters": "Recall", "trade_sell": "Sell", "shop_buy_qty": "Buy qty", "shop_sell_qty": "Sell qty",
	"ship_info": "Info", "launch": "Launch", "bbs_accept": "Accept", "map_pan_left": "Pan L", "map_pan_right": "Pan R",
	"map_pan_up": "Pan U", "map_pan_down": "Pan D", "map_zoom_in": "Zoom +", "map_zoom_out": "Zoom -",
	"map_select": "Plot", "map_extend": "Add hop", "map_auto_route": "Auto", "map_center": "Centre", "map_find": "Find",
	"map_close": "Close",
}


## A short name for a keycap (fits a 1u key in one or two lines).
static func short_label(action: String) -> String:
	return str(_SHORT.get(action, label_of(action)))


static func key_name(code: int) -> String:
	match code:
		KEY_CTRL: return "Ctrl"
		KEY_ALT: return "Alt"
		KEY_SHIFT: return "Shift"
		KEY_META: return "Super"
	return OS.get_keycode_string(code)


## The key field an action is bound through right now (so the layer selector follows the action),
## else the one it is declared with, else "keys".
static func field_of(action: String) -> String:
	var spec: Dictionary = Controls.effective(action)
	for f in ["keys", "shift_keys", "alt_keys"]:
		if not (spec.get(f, []) as Array).is_empty():
			return f
	var base: Dictionary = Controls.BINDINGS[action]
	if base.has("keys"):
		return "keys"
	return "shift_keys" if base.has("shift_keys") else ("alt_keys" if base.has("alt_keys") else "keys")


static func layer_of_field(field: String) -> int:
	return maxi(0, LAYER_FIELDS.find(field))


## key code -> Array of actions of `group` bound to it through `field`, in GROUPS order.
static func key_map(group: String, field: String) -> Dictionary:
	var out: Dictionary = {}
	for action in Controls.GROUPS.get(group, []):
		for code in Controls.effective(action).get(field, []):
			var list: Array = out.get(int(code), [])
			list.append(action)
			out[int(code)] = list
	return out


## key code -> true when `group` binds it through a field other than `field` (the corner dot).
static func other_layer_codes(group: String, field: String) -> Dictionary:
	var out: Dictionary = {}
	for f in LAYER_FIELDS:
		if f == field:
			continue
		for code in key_map(group, f):
			out[int(code)] = true
	return out


## JoyButton -> Array of actions of `group` bound to it.
static func pad_map(group: String) -> Dictionary:
	var out: Dictionary = {}
	for action in Controls.GROUPS.get(group, []):
		for b in Controls.effective(action).get("buttons", []):
			var list: Array = out.get(int(b), [])
			list.append(action)
			out[int(b)] = list
	return out


## action -> true for rows sharing a key (or pad button) with another action of the group.
static func conflicts(group: String, field: String) -> Dictionary:
	var out: Dictionary = {}
	var maps: Array = [key_map(group, field), pad_map(group)] if field != "buttons" else [pad_map(group)]
	for m in maps:
		for code in m:
			var list: Array = m[code]
			if list.size() < 2:
				continue
			for a in list:
				for b in list:
					if a != b and _CONTEXT_PAIRS.get(a, "") != b and _CONTEXT_PAIRS.get(b, "") != a:
						out[a] = true
	return out


## Remove a single physical input from an action's binding of `field`.
static func unbind(action: String, field: String, code: int) -> void:
	var arr: Array = (Controls.effective(action).get(field, []) as Array).duplicate()
	arr.erase(code)
	var o: Dictionary = Controls.overrides.get(action, {})
	o[field] = arr
	Controls.overrides[action] = o
	Controls.register()


## Bind `code` to `action` (swap-on-conflict, Controls.rebind). Returns the swapped action or "".
static func assign(action: String, field: String, code: int) -> String:
	var swapped := Controls.rebind(action, field, code)
	Controls.register()
	return swapped


# --- picker choices (persisted in Prefs [input]) -------------------------------------------

const PRESETS := ["full", "tkl", "compact"]
const PRESET_NAMES := ["Full", "Tenkeyless", "Compact"]
const PAD_STYLES := ["xbox", "playstation", "switch", "deck"]
const PAD_STYLE_NAMES := ["Xbox", "PlayStation", "Nintendo Switch Pro", "Steam Deck"]


static func preset() -> String:
	var p := str(Prefs.get_value("input", "ctl_preset"))
	return p if p in PRESETS else "full"


static func pad_style() -> String:
	var s := str(Prefs.get_value("input", "ctl_pad_style"))
	if s in PAD_STYLES:
		return s
	return detect_pad_style()


## Style from the connected pad's name; Steam Deck first; fallback Xbox.
static func detect_pad_style() -> String:
	if OS.get_environment("SteamDeck") == "1":
		return "deck"
	for d in Input.get_connected_joypads():
		var n := Input.get_joy_name(d).to_lower()
		if n.contains("steam deck") or n.contains("steamdeck") or n.contains("neptune"):
			return "deck"
		if n.contains("dualsense") or n.contains("dualshock") or n.contains("playstation") or n.contains("ps5") \
				or n.contains("ps4") or n.contains("ps3") or n.contains("sony") or n.contains("ps controller"):
			return "playstation"
		if n.contains("nintendo") or n.contains("pro controller") or n.contains("switch"):
			return "switch"
		if n.contains("xbox") or n.contains("xinput"):
			return "xbox"
	return "xbox"

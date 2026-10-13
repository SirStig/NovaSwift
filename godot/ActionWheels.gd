# NOVA Swift -- Godot action wheels: the data side (mirrors app/NovaSwift/Input/ActionWheels.swift).
#
# Steam-style radial menus: HOLD a wheel's trigger button, flick the right stick toward a slot, release to use
# it; a quick tap still does the button's normal bound action (fired on release by ui/ActionWheel.gd, because
# Controls.register strips the trigger buttons off the Flight-group actions they used to drive).
#
# A wheel is a Dictionary {id, title, trigger: JoyButton, slots: Array[String] (action names, 4..12, clockwise from
# the top), anchor: "left" | "right"}. The player's edits persist in settings.cfg [wheels] (Prefs.gd): only wheels that
# differ from the defaults are written, one key per wheel id, plus `pause` (game pauses while a wheel is open).
#
# Preloaded (no class_name), like Controls.gd. Controls.gd must not preload this file (this one preloads Controls);
# the trigger set reaches Controls through Controls.wheel_triggers via sync().
extends RefCounted

const Controls = preload("res://Controls.gd")

const MIN_SLOTS := 4
const MAX_SLOTS := 12
## Hold this long (s) and the wheel opens; release sooner and it was a tap.
const HOLD_DELAY := 0.22

## Actions that are held controls: they can't be a one-shot slot (self_destruct is latched instead) and a button
## bound to one can't be a trigger.
const CONTINUOUS := ["turn_left", "turn_right", "thrust", "reverse", "afterburner", "fire_primary",
	"fire_secondary", "self_destruct"]
## Right-stick aim actions are analog, never slots.
const STICK_ACTIONS := ["aim_left", "aim_right", "aim_up", "aim_down"]

## While the Escort Commands panel is up, a wheel containing `escort_panel` is replaced by this one so a pad can pick
## escort group 1-5 (the keyboard presses 1-5). Not editable.
const ESCORT_WHEEL := {"id": "escort_groups", "title": "Escort Groups", "trigger": -1, "anchor": "left",
	"slots": ["escort_group_1", "escort_group_2", "escort_group_3", "escort_group_4", "escort_group_5",
		"escort_panel"]}

static var wheels: Array = defaults()
## "Pause while a wheel is open" (settings.cfg [wheels] pause); mirrored here by Prefs.
static var pause_while_open := true


static func defaults() -> Array:
	return [
		{"id": "combat", "title": "Combat & Fleet", "trigger": JOY_BUTTON_LEFT_SHOULDER, "anchor": "left",
			"slots": ["toggle_cloak", "escort_attack", "escort_defend", "escort_hold", "escort_formation",
				"escort_return", "recall_fighters", "escort_panel", "clear_secondary", "eject", "self_destruct"]},
		{"id": "nav", "title": "Targeting & Nav", "trigger": JOY_BUTTON_RIGHT_SHOULDER, "anchor": "right",
			"slots": ["target_nearest", "target_prev", "target_escort_next", "clear_ship_target",
				"nav_stellar_1", "nav_stellar_2", "nav_stellar_3", "nav_stellar_4", "hail_stellar",
				"hyperspace_arm", "cycle_hyperspace_link", "cycle_hyperspace_link_prev"]},
		{"id": "info", "title": "Info & View", "trigger": JOY_BUTTON_BACK, "anchor": "left",
			"slots": ["player_info", "mission_info", "dismiss_message", "route_map_zoom_in",
				"route_map_zoom_out", "pause_menu"]},
	]


static func default_anchor(trigger: int) -> String:
	return "right" if trigger == JOY_BUTTON_RIGHT_SHOULDER or trigger == JOY_BUTTON_RIGHT_STICK \
		or trigger == JOY_BUTTON_DPAD_RIGHT or trigger == JOY_BUTTON_X or trigger == JOY_BUTTON_A else "left"


static func wheel_for(button: int) -> Dictionary:
	for w in wheels:
		if int((w as Dictionary).get("trigger", -1)) == button:
			return w
	return {}


static func wheel_by_id(id: String) -> Dictionary:
	for w in wheels:
		if str((w as Dictionary).get("id", "")) == id:
			return w
	return {}


static func trigger_buttons() -> Array:
	var out: Array = []
	for w in wheels:
		out.append(int((w as Dictionary).get("trigger", -1)))
	return out


## Push the trigger set onto Controls (so register() strips them off the Flight actions) and re-register.
static func sync(register_now: bool = true) -> void:
	Controls.wheel_triggers = trigger_buttons()
	if register_now:
		Controls.register()


static func reset_to_defaults() -> void:
	wheels = defaults()
	sync()


static func is_slot_eligible(action: String) -> bool:
	return action in Controls.GROUPS["Flight"] and (not (action in CONTINUOUS) or action == "self_destruct")


## Whether `button` may become a wheel trigger: not bound to a held Flight control.
static func can_trigger(button: int) -> bool:
	for a in CONTINUOUS:
		if button in Controls.effective(a).get("buttons", []):
			return false
	return true


## Actions the pad can't reach: a Flight action with no pad button/axis, in no wheel slot. Escort groups count as
## reachable when the Escort Commands panel is (the escort wheel swaps in while it's open).
static func uncovered() -> Array:
	var in_wheel: Dictionary = {}
	for w in wheels:
		for a in (w as Dictionary).get("slots", []):
			in_wheel[str(a)] = true
	var out: Array = []
	var panel_ok: bool = in_wheel.has("escort_panel") or not (Controls.effective("escort_panel").get("buttons", []) as Array).is_empty()
	for a in Controls.GROUPS["Flight"]:
		var spec: Dictionary = Controls.effective(a)
		if not (spec.get("buttons", []) as Array).is_empty() or not (spec.get("axes", []) as Array).is_empty():
			continue
		if in_wheel.has(a):
			continue
		if (a as String).begins_with("escort_group_") and panel_ok:
			continue
		out.append(a)
	return out


## Slot for a compass angle (radians, 0 = up, clockwise positive).
static func slot_for_angle(angle: float, count: int) -> int:
	if count <= 0:
		return 0
	var step: float = TAU / float(count)
	var i: int = int(round(angle / step))
	return ((i % count) + count) % count


## Slot under a stick vector (x right, y DOWN as Godot reports it); -1 inside the threshold.
static func slot_for_stick(v: Vector2, count: int, threshold: float = 0.5) -> int:
	if count <= 0 or v.length() <= threshold:
		return -1
	return slot_for_angle(atan2(v.x, -v.y), count)


# MARK: Persistence ------------------------------------------------------------------------------------------

## Only wheels that differ from the defaults: id -> {trigger, slots, anchor}.
static func to_store() -> Dictionary:
	var out: Dictionary = {}
	var defs: Array = defaults()
	for w in wheels:
		var wd: Dictionary = w
		var same := false
		for d in defs:
			var dd: Dictionary = d
			if dd["id"] == wd["id"] and int(dd["trigger"]) == int(wd["trigger"]) and dd["slots"] == wd["slots"] \
					and str(dd["anchor"]) == str(wd.get("anchor", "")):
				same = true
		if not same:
			out[wd["id"]] = {"trigger": int(wd["trigger"]), "slots": (wd["slots"] as Array).duplicate(),
				"anchor": str(wd.get("anchor", "left"))}
	return out


## Start from the defaults and lay the stored wheels over them. Unknown actions drop out; a wheel left with too
## few slots, or whose trigger can't be one, keeps its default.
static func from_store(store: Dictionary) -> void:
	wheels = defaults()
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var s: Variant = store.get(w["id"])
		if not (s is Dictionary):
			continue
		var slots: Array = []
		for a in (s as Dictionary).get("slots", []):
			if is_slot_eligible(str(a)):
				slots.append(str(a))
		if slots.size() < MIN_SLOTS or slots.size() > MAX_SLOTS:
			continue
		var trig: int = int((s as Dictionary).get("trigger", w["trigger"]))
		w["slots"] = slots
		w["trigger"] = trig
		w["anchor"] = str((s as Dictionary).get("anchor", default_anchor(trig)))
	sync(false)

# Headless check of the action wheels (ActionWheels.gd data, ui/ActionWheel.gd input + overlay, Main.gd hooks,
# Prefs [wheels] persistence, the editor page). Synthetic pad events go through Input.parse_input_event; the right
# stick is the aim_* actions. Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/action_wheel_selfcheck.gd
extends SceneTree

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const ActionWheels = preload("res://ActionWheels.gd")
const WheelsPage = preload("res://screens/controls_editor/WheelsPage.gd")

var ok := true
var main
var nova
var wheel
var counts: Dictionary = {}


## Counts each just-pressed edge of the watched actions, once per frame.
class Counter extends Node:
	var counts: Dictionary = {}
	var watch: Array = []
	func _process(_d: float) -> void:
		for a in watch:
			if Input.is_action_just_pressed(a):
				counts[a] = int(counts.get(a, 0)) + 1


func _init() -> void:
	_run()


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false
	return cond


func _btn(b: int, pressed: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = pressed
	Input.parse_input_event(e)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _wait(sec: float) -> void:
	await create_timer(sec).timeout
	await process_frame


func _stick(action: String, on: bool) -> void:
	if on:
		Input.action_press(action, 1.0)
	else:
		Input.action_release(action)


func _run() -> void:
	await process_frame
	Prefs.path = "user://wheel_selfcheck.cfg"   # never touch the real settings.cfg
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Prefs.path))
	Prefs.load_all()

	print("== data ==")
	_check("defaults leave nothing unreachable", ActionWheels.uncovered().is_empty())
	_check("three default wheels on LB / RB / Back", ActionWheels.wheels.size() == 3
		and ActionWheels.wheel_for(JOY_BUTTON_LEFT_SHOULDER)["id"] == "combat"
		and ActionWheels.wheel_for(JOY_BUTTON_RIGHT_SHOULDER)["id"] == "nav"
		and ActionWheels.wheel_for(JOY_BUTTON_BACK)["id"] == "info")
	_check("slot counts within 4..12", ActionWheels.wheels.all(func(w: Dictionary) -> bool:
		return (w["slots"] as Array).size() >= 4 and (w["slots"] as Array).size() <= 12))
	_check("anchors: LB left, RB right, Back left", ActionWheels.wheel_for(JOY_BUTTON_LEFT_SHOULDER)["anchor"] == "left"
		and ActionWheels.wheel_for(JOY_BUTTON_RIGHT_SHOULDER)["anchor"] == "right"
		and ActionWheels.wheel_for(JOY_BUTTON_BACK)["anchor"] == "left")
	_check("slot angle math (8 slots)", ActionWheels.slot_for_stick(Vector2(0, -1), 8) == 0
		and ActionWheels.slot_for_stick(Vector2(1, 0), 8) == 2 and ActionWheels.slot_for_stick(Vector2(0, 1), 8) == 4
		and ActionWheels.slot_for_stick(Vector2(-1, 0), 8) == 6 and ActionWheels.slot_for_stick(Vector2(0.2, 0.2), 8) == -1
		and ActionWheels.slot_for_stick(Vector2(-0.05, -1), 8) == 0 and ActionWheels.slot_for_stick(Vector2(-0.4, -1), 8) == 0)
	_check("slot angle wraps (11 slots, just left of top)", ActionWheels.slot_for_stick(Vector2(-0.1, -1), 11) == 0
		and ActionWheels.slot_for_stick(Vector2(-0.6, -1), 11) == 10)
	# Reachability warning: strip a wheel slot and the action shows up.
	var saved: Array = ActionWheels.wheels.duplicate(true)
	(ActionWheels.wheels[2]["slots"] as Array).erase("player_info")
	_check("removing a slot is reported", "player_info" in ActionWheels.uncovered())
	ActionWheels.wheels = saved

	print("== persistence ==")
	var w0: Dictionary = ActionWheels.wheels[0]
	w0["trigger"] = JOY_BUTTON_DPAD_UP
	w0["slots"] = ["toggle_cloak", "eject", "land", "hyperjump"]
	w0["anchor"] = "right"
	Prefs.set_value("wheels", "pause", false)
	Prefs.save()
	ActionWheels.reset_to_defaults()
	ActionWheels.pause_while_open = true
	Prefs.load_all()
	var back: Dictionary = ActionWheels.wheel_by_id("combat")
	_check("customised wheel round-trips", int(back["trigger"]) == JOY_BUTTON_DPAD_UP and back["slots"] == ["toggle_cloak", "eject", "land", "hyperjump"]
		and back["anchor"] == "right")
	_check("untouched wheels stay default", ActionWheels.wheel_by_id("nav")["slots"] == ActionWheels.defaults()[1]["slots"])
	_check("pause setting round-trips", ActionWheels.pause_while_open == false)
	ActionWheels.reset_to_defaults()
	Prefs.set_value("wheels", "pause", true)
	Prefs.save()
	Prefs.load_all()
	_check("reset returns to defaults (nothing stored)", ActionWheels.to_store().is_empty() and ActionWheels.pause_while_open)

	print("== editor page ==")
	var page: Control = WheelsPage.new()
	root.add_child(page)
	page.setup()
	await process_frame
	_check("page builds trigger + slots + add for each wheel", page.find_child("fk_combat_trigger", true, false) != null
		and page.find_child("fk_nav_slot_11", true, false) != null and page.find_child("fk_info_add", true, false) != null)
	var add: Button = page.find_child("fk_info_add", true, false)
	add.pressed.emit()
	await process_frame
	_check("Add slot appends to the Info wheel", (ActionWheels.wheel_by_id("info")["slots"] as Array).size() == 7)
	var rm: Button = page.find_child("fk_info_rm_6", true, false)
	rm.pressed.emit()
	await process_frame
	_check("Remove slot shrinks it back", (ActionWheels.wheel_by_id("info")["slots"] as Array).size() == 6)
	page.queue_free()
	ActionWheels.reset_to_defaults()

	print("== input (Main) ==")
	OS.set_environment("NOVA_SKIP_PILOT_MENU", "1")
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	await _frames(12)
	nova = main.nova
	wheel = main._wheel
	if not _check("Main built a world with a wheel node", nova != null and main._has_data and wheel != null):
		quit(1)
		return
	Controls.register()
	_check("LB / RB / Back stripped from their Flight actions", not InputMap.event_is_action(_ev(JOY_BUTTON_LEFT_SHOULDER), "secondary_prev")
		and not InputMap.event_is_action(_ev(JOY_BUTTON_RIGHT_SHOULDER), "secondary_next")
		and not InputMap.event_is_action(_ev(JOY_BUTTON_BACK), "galaxy_map"))
	_check("map zoom still on LB / RB, B still fire_secondary", InputMap.event_is_action(_ev(JOY_BUTTON_LEFT_SHOULDER), "map_zoom_out")
		and InputMap.event_is_action(_ev(JOY_BUTTON_RIGHT_SHOULDER), "map_zoom_in")
		and InputMap.event_is_action(_ev(JOY_BUTTON_B), "fire_secondary"))
	_check("shop_sell_qty keeps RB", InputMap.event_is_action(_ev(JOY_BUTTON_RIGHT_SHOULDER), "shop_sell_qty"))
	_check("wheel is live in plain flight", wheel.live)

	var ctr := Counter.new()
	ctr.watch = ["secondary_prev", "secondary_next", "toggle_cloak", "escort_hold", "fire_secondary", "galaxy_map"]
	root.add_child(ctr)

	# Tap
	_btn(JOY_BUTTON_LEFT_SHOULDER, true)
	await _frames(3)
	_check("tap: nothing fires on press", int(ctr.counts.get("secondary_prev", 0)) == 0 and not wheel.is_open())
	_btn(JOY_BUTTON_LEFT_SHOULDER, false)
	await _frames(4)
	_check("tap LB fires secondary_prev exactly once on release", int(ctr.counts.get("secondary_prev", 0)) == 1)
	_btn(JOY_BUTTON_RIGHT_SHOULDER, true)
	await _frames(2)
	_btn(JOY_BUTTON_RIGHT_SHOULDER, false)
	await _frames(4)
	_check("tap RB fires secondary_next once", int(ctr.counts.get("secondary_next", 0)) == 1)

	# A stick already aiming at press time keeps a tap a tap
	_stick("aim_up", true)
	await _frames(2)
	_btn(JOY_BUTTON_LEFT_SHOULDER, true)
	await _frames(3)
	_check("stick already aiming at press does not open the wheel", not wheel.is_open())
	_btn(JOY_BUTTON_LEFT_SHOULDER, false)
	await _frames(4)
	_check("... and the release was a tap", int(ctr.counts.get("secondary_prev", 0)) == 2)
	_stick("aim_up", false)
	await _frames(3)

	# Hold: opens by time, paused, stick picks, release fires
	var p0: Vector2 = nova.player_position()
	Input.action_press("thrust")
	_btn(JOY_BUTTON_LEFT_SHOULDER, true)
	await _wait(0.4)
	_check("held LB opens the Combat wheel", wheel.is_open() and wheel.open_wheel()["id"] == "combat")
	_stick("aim_right", true)
	await _frames(3)
	var want: int = ActionWheels.slot_for_stick(Vector2(1, 0), 11)
	_check("right stick highlights slot %d" % want, wheel.highlighted() == want)
	_stick("aim_right", false)
	await _frames(3)
	_check("pick is sticky after recentring", wheel.highlighted() == want)
	_check("game is paused while open", wheel.pausing())
	var p1: Vector2 = nova.player_position()
	await _wait(0.3)
	_check("sim holds still while the wheel is open", nova.player_position() == p1)
	_btn(JOY_BUTTON_LEFT_SHOULDER, false)
	await _frames(4)
	var slot_action: String = ActionWheels.wheel_by_id("combat")["slots"][want]
	_check("release fires the slot (%s) and closes" % slot_action, not wheel.is_open() and slot_action == "escort_hold"
		and int(ctr.counts.get("escort_hold", 0)) == 1)
	await _wait(0.4)
	_check("sim resumes after the wheel closes", nova.player_position() != p1)
	Input.action_release("thrust")

	# Slot 0 (toggle_cloak) by pushing the stick AFTER the press opens the wheel before 0.22 s
	var cloak0: int = int(ctr.counts.get("toggle_cloak", 0))
	_btn(JOY_BUTTON_LEFT_SHOULDER, true)
	await process_frame
	_stick("aim_up", true)
	await _frames(3)
	_check("stick push after press opens early", wheel.is_open() and wheel.highlighted() == 0)
	_btn(JOY_BUTTON_LEFT_SHOULDER, false)
	await _frames(4)
	_stick("aim_up", false)
	_check("hold + stick + release fires slot 0 (toggle_cloak)", int(ctr.counts.get("toggle_cloak", 0)) == cloak0 + 1)
	await _frames(3)

	# B cancels without firing the secondary
	var cloak1: int = int(ctr.counts.get("toggle_cloak", 0))
	var fs0: int = int(ctr.counts.get("fire_secondary", 0))
	_btn(JOY_BUTTON_LEFT_SHOULDER, true)
	await _wait(0.35)
	_stick("aim_up", true)
	await _frames(3)
	_btn(JOY_BUTTON_B, true)
	await _frames(3)
	_check("B closes the wheel", not wheel.is_open())
	_check("B cancel does not fire_secondary through Main", not main._held("fire_secondary"))
	_btn(JOY_BUTTON_LEFT_SHOULDER, false)
	await _frames(4)
	_stick("aim_up", false)
	_btn(JOY_BUTTON_B, false)
	await _frames(3)
	_check("cancelled wheel fires nothing", int(ctr.counts.get("toggle_cloak", 0)) == cloak1)
	_check("fire_secondary is live again after B is released", not main._suppressed.has("fire_secondary"))
	await _wait(0.3)
	_check("overlay fades out", wheel._anim == 0.0)

	# Never-selected hold cancels
	_btn(JOY_BUTTON_RIGHT_SHOULDER, true)
	await _wait(0.4)
	_check("RB hold opens the Targeting & Nav wheel", wheel.is_open() and wheel.open_wheel()["id"] == "nav")
	var sn0: int = int(ctr.counts.get("secondary_next", 0))
	_btn(JOY_BUTTON_RIGHT_SHOULDER, false)
	await _frames(4)
	_check("hold with no pick cancels (no tap either)", not wheel.is_open() and int(ctr.counts.get("secondary_next", 0)) == sn0)

	# Layout: anchors low on the trigger's side
	var lay_l: Dictionary = wheel.layout_for(ActionWheels.wheel_by_id("combat"), Vector2(1280, 720))
	var lay_r: Dictionary = wheel.layout_for(ActionWheels.wheel_by_id("nav"), Vector2(1280, 720))
	_check("LB wheel bottom-left, RB wheel bottom-right", (lay_l["center"] as Vector2).x < 640 and (lay_l["center"] as Vector2).y > 360
		and (lay_r["center"] as Vector2).x > 640 and (lay_r["center"] as Vector2).y > 360)
	_check("wheel keeps >= 32 px from the edge", (lay_l["center"] as Vector2).x - float(lay_l["radius"]) >= 32.0
		and 720.0 - (lay_l["center"] as Vector2).y - float(lay_l["radius"]) >= 32.0)

	ctr.queue_free()
	main.queue_free()
	ActionWheels.reset_to_defaults()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Prefs.path))
	Prefs.path = Prefs.PATH
	Prefs.load_all()
	print("ACTION WHEEL SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _ev(b: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = b
	e.pressed = true
	return e

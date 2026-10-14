# NOVA Swift — flight training: the offer shown to a brand-new pilot and the coaching overlay.
#
# Port of the Apple app's Tutorial/ folder. The rules are shared Swift (NovaSwiftStory
# `TutorialCurriculum` steps + `TutorialProgression` machine, behind the bridge's `tutorial_*`
# calls); this file is the presentation and the watching of the live flight:
#
#   Tutorial.make_offer(nova, host)  -> TutorialOfferView: "Flight Training" dialog, Skip / Start
#                                       Training (Classic dialog panel or the plain Nova Swift panel)
#   Tutorial.new().setup(nova, ...)  -> TutorialCoachView over the training flight (a throwaway
#                                       pilot the bridge swaps in: invulnerable, never saved, landing
#                                       only completes the lesson). A bottom card with the step's
#                                       title / instruction / progress dots, "Continue" (finish
#                                       label on the last card) on manual steps, "Try it - this
#                                       advances on its own" + "Skip step" on objective ones, and an
#                                       always-available "Skip Tutorial".
#
# Wording follows the control style: a connected pad names its buttons ("A", "RB"), else the bound
# keys (Controls.describe_*). Objective watching (Apple TutorialContainerView.sample, 5 Hz): fly =
# 650 px travelled since the step began, turn = 1.2 rad of heading change, afterburner = engaged,
# target = a lock, fire = the primary fire action, change weapon = a secondary cycle, land =
# the bridge's tutorial_take_landed. Buttons are mouse-only on purpose (A / Space fire the ship):
# keyboard Enter / pad A continue on manual cards, Backspace skips a step, Delete skips the tutorial,
# and Esc / Start opens the pause menu whose entry reads "Leave Training".
#
# Loaded with preload() (no class_name), like the other screens.
extends CanvasLayer

const Controls = preload("res://Controls.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const ShellUI = preload("res://screens/ShellUI.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")
const Icons = preload("res://ui/novaswift/NovaIcons.gd")

## The course ended (finished, or Skip Tutorial / Leave Training).
signal finished

const AMBER := Color(1.0, 0.7, 0.28)
const FLY_DISTANCE := 650.0       # Apple: distanceSinceBaseline > 650
const TURN_RADIANS := 1.2         # Apple: |angle delta| > 1.2
const SAMPLE_EVERY := 0.2         # Apple: Timer 0.2 s

# TutorialAction raw value -> Godot input action (Apple GameAction names -> Controls.BINDINGS).
const ACTIONS := {"accelerate": "thrust", "turnLeft": "turn_left", "turnRight": "turn_right",
	"afterburner": "afterburner", "targetNearest": "target_nearest", "nearestHostile": "target_nearest_hostile",
	"targetNext": "target_next", "firePrimary": "fire_primary", "selectSecondaryNext": "secondary_next",
	"selectSecondaryPrev": "secondary_prev", "land": "land"}

var finish_label := "Done"
var state: Dictionary = {}

var _nova: Object
var _shell: Object
var _card: PanelContainer
var _root: Control
var _clock := 0.0
var _travelled := 0.0
var _last_pos := Vector2.ZERO
var _baseline_angle := 0.0
var _index_seen := -1
var _has_secondary := false
var _done := false


# --- the offer (TutorialOfferView) ---------------------------------------------------------

const OFFER_TEXT := "New to the cockpit? Take a short practice flight to learn how to fly, fight, switch weapons and land your ship."
const OFFER_NOTE := "It won't affect your pilot, and you can skip it any time."


## Show the training offer over `host` (a Node); returns an object with signals `start` and `skip`.
static func make_offer(nova: Object, host: Node) -> Node:
	var o: Node = _Offer.new()
	host.add_child(o)
	o.setup(nova)
	return o


class _Offer extends CanvasLayer:
	signal start
	signal skip
	var dialog: Control        # the ClassicDialog when drawn in Classic presentation
	var buttons := {}          # "start" / "skip" -> Button
	var _nova: Object

	func setup(nova: Object) -> void:
		_nova = nova
		layer = 70
		ClassicTheme.setup(nova)
		if ClassicTheme.classic("dialogs"):
			dialog = ClassicDialog.panel(nova, {"title": "Flight Training", "width": 460,
				"text": OFFER_TEXT + "\n" + OFFER_NOTE,
				"footer_buttons": [{"label": "Skip", "action": func(): skip.emit(), "cancel": true},
					{"label": "Start Training", "action": func(): start.emit(), "default": true}]})
			ClassicDialog.modal(self, dialog, 0.6)
			buttons["skip"] = dialog.item(0)
			buttons["start"] = dialog.item(1)
			return
		# TutorialOfferView: NovaDialog "Flight Training" (Skip / Start Training).
		var d := Chrome.dialog(self, {"title": "Flight Training", "width": 460.0, "buttons": [
			{"text": "Skip", "cb": func(): skip.emit()},
			{"text": "Start Training", "default": true, "cb": func(): start.emit()}]})
		NC.label(d.body, OFFER_TEXT, "body", "regular", T.WHITE, true)
		NC.label(d.body, OFFER_NOTE, "caption", "regular", Color(1, 1, 1, 0.65), true)
		buttons["start"] = d.buttons["Start Training"]
		buttons["skip"] = d.buttons["Skip"]

	func _unhandled_input(event: InputEvent) -> void:
		if dialog == null and event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			skip.emit()


# --- the coach ---------------------------------------------------------------------------------

## Start the course. `shell` answers `is_paused()` / `in_menu()` (the overlay hides while a menu is up).
func setup(nova: Object, shell: Object, label: String) -> void:
	_nova = nova
	_shell = shell
	finish_label = label
	layer = 40
	var caps = JSON.parse_string(nova.tutorial_capabilities())
	var has_ab := bool(caps.get("afterburner", false)) if caps is Dictionary else false
	_has_secondary = bool(caps.get("secondary", false)) if caps is Dictionary else false
	var pad := Controls.pad_connected()
	nova.tutorial_start("pad" if pad else "keyboard", JSON.stringify(_labels(pad)), has_ab, _has_secondary)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_refresh()
	_rebaseline()


## The label for each control the instruction text names: pad button names when a pad is connected
## (falling back to the bound key), else the bound keys.
func _labels(pad: bool) -> Dictionary:
	var out := {}
	for ta in ACTIONS:
		var act: String = ACTIONS[ta]
		var text := ""
		if pad:
			text = Controls.describe_buttons(act)
		if text == "" or text == "—":
			text = Controls.describe_keys(act)
		out[ta] = text
	return out


func current_step() -> Dictionary:
	var steps: Array = state.get("steps", [])
	var i := int(state.get("index", 0))
	return steps[i] if i >= 0 and i < steps.size() else {}


func _refresh() -> void:
	var parsed = JSON.parse_string(_nova.tutorial_state())
	state = parsed if parsed is Dictionary else {}
	if bool(state.get("finished", false)):
		_finish()
		return
	_build_card()


func _rebaseline() -> void:
	_travelled = 0.0
	_baseline_angle = _nova.player_angle()
	_last_pos = _nova.player_position()
	_index_seen = int(state.get("index", 0))


# --- the card ----------------------------------------------------------------------------------

func _build_card() -> void:
	for c in _root.get_children():
		c.queue_free()
	var step := current_step()
	if step.is_empty():
		return
	# Skip Tutorial, always available, top right: a dark capsule with a hairline (TutorialCoachView).
	var skip := Button.new()
	skip.text = "Skip Tutorial"
	skip.icon = T.icon("xmark", 12, Color(1, 1, 1, 0.85))
	skip.add_theme_constant_override("h_separation", 6)
	skip.focus_mode = Control.FOCUS_NONE
	skip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	skip.position = Vector2(-158, 10)
	var cap := T.box(Color(0, 0, 0, 0.55), 20, Color(1, 1, 1, 0.18), 1, Vector2(12, 7))
	for st in ["normal", "hover", "pressed"]:
		skip.add_theme_stylebox_override(st, cap)
	T.style_text(skip, "caption", "semibold", Color(1, 1, 1, 0.85))
	skip.pressed.connect(_finish)
	_root.add_child(skip)

	_card = PanelContainer.new()
	_card.theme = T.theme()
	_card.add_theme_stylebox_override("panel", T.box(Color(0, 0, 0, 0.8), 16, Color(AMBER.r, AMBER.g, AMBER.b, 0.35), 1, Vector2(18, 18)))
	_card.custom_minimum_size = Vector2(460, 0)
	_card.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_card.position = Vector2(-230, -26)
	_root.add_child(_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_card.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	var sym := str(step.get("icon", ""))
	NC.icon_rect(head, sym if Icons.has(sym) else "sparkles", 22, AMBER)
	var tcol := VBoxContainer.new()
	tcol.add_theme_constant_override("separation", 1)
	tcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(tcol)
	NC.label(tcol, str(step["title"]), "heading", "bold", T.WHITE)
	NC.label(tcol, "Step %d of %d" % [int(state["number"]), int(state["count"])], "caption", "regular", Color(1, 1, 1, 0.55))
	var body := NC.label(v, str(step["body"]), "body", "regular", Color(1, 1, 1, 0.92), true)
	body.custom_minimum_size = Vector2(424, 0)
	v.add_child(_dots())
	v.add_child(_footer(step))


func _dots() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var n := int(state["count"])
	for i in n:
		var d := Panel.new()
		d.add_theme_stylebox_override("panel", T.box(AMBER if i <= int(state["index"]) else Color(1, 1, 1, 0.22), 3))
		d.custom_minimum_size = Vector2(16 if i == int(state["index"]) else 7, 5)
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(d)
	return h


func _footer(step: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	if str(step.get("goal", "")) == "":
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(sp)
		var hint := NC.label(h, "A / Enter" if Controls.pad_connected() else "Enter", "caption", "regular", Color(1, 1, 1, 0.45))
		hint.add_theme_font_size_override("font_size", 11)
		# the amber capsule (22 / 9 padding, black text)
		var b := NC.button(finish_label if bool(state["is_last"]) else "Continue", "pill_default", continue_step)
		var cb := T.box(AMBER, 20, Color(0, 0, 0, 0), 0, Vector2(22, 9))
		for st in ["normal", "hover", "pressed"]:
			b.add_theme_stylebox_override(st, cb)
		b.focus_mode = Control.FOCUS_NONE
		h.add_child(b)
	else:
		NC.progress(h, 0.4, 14)
		var l := NC.label(h, "Try it — this advances on its own", "caption", "regular", Color(1, 1, 1, 0.6))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var s := NC.button("Skip step ›", "plain", skip_step)
		T.style_text(s, "caption", "semibold", Color(1, 1, 1, 0.7))
		s.focus_mode = Control.FOCUS_NONE
		h.add_child(s)
	return h


# --- driving the course --------------------------------------------------------------------------

## Continue on a manual card; the last card's button ends the course.
func continue_step() -> void:
	if _done:
		return
	if bool(state.get("is_last", false)):
		_finish()
		return
	_nova.tutorial_advance()
	_refresh()
	_rebaseline()


## "Skip step" on an objective card.
func skip_step() -> void:
	if _done:
		return
	_nova.tutorial_advance()
	_refresh()
	_rebaseline()


## An observed goal: advances only when the current step waits on exactly it.
func complete(goal: String) -> void:
	if _done:
		return
	_nova.tutorial_complete(goal)
	_refresh()
	if not _done and int(state.get("index", 0)) != _index_seen:
		_rebaseline()


func _finish() -> void:
	if _done:
		return
	_done = true
	finished.emit()


func _hidden() -> bool:
	return _shell != null and (_shell.is_paused() or _shell.in_menu())


func _process(delta: float) -> void:
	if _done or _root == null:
		return
	_root.visible = not _hidden()
	if _hidden():
		return
	# Event-driven goals (Apple onPlayerFired / handleDiscrete / landAttempt).
	if InputMap.has_action("fire_primary") and Input.is_action_just_pressed("fire_primary"):
		complete("fire")
	if _has_secondary and InputMap.has_action("secondary_next") and InputMap.has_action("secondary_prev") and (Input.is_action_just_pressed("secondary_next") or Input.is_action_just_pressed("secondary_prev")):
		complete("changeWeapon")
	if _nova.tutorial_take_landed():
		complete("land")
	_clock += delta
	if _clock >= SAMPLE_EVERY:
		_clock = 0.0
		sample()


## Apple's 5 Hz poll: accumulate travel and check the current step's goal.
func sample() -> void:
	if _done:
		return
	var pos: Vector2 = _nova.player_position()
	_travelled += pos.distance_to(_last_pos)
	_last_pos = pos
	match str(current_step().get("goal", "")):
		"fly":
			if _travelled > FLY_DISTANCE:
				complete("fly")
		"turn":
			if absf(_angle_delta(_nova.player_angle(), _baseline_angle)) > TURN_RADIANS:
				complete("turn")
		"afterburner":
			if Input.is_action_pressed("afterburner") or _nova.tutorial_afterburner_active():
				complete("afterburner")
		"target":
			if int(_nova.player_target_id()) >= 0:
				complete("target")


## Shortest signed angular difference a - b, wrapped to (-PI, PI].
static func _angle_delta(a: float, b: float) -> float:
	var d := fposmod(a - b, TAU)
	if d > PI:
		d -= TAU
	return d


func _unhandled_input(event: InputEvent) -> void:
	if _done or _hidden():
		return
	var step := current_step()
	if str(step.get("goal", "")) == "" and (event.is_action_pressed("ui_accept")
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER])):
		get_viewport().set_input_as_handled()
		continue_step()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_BACKSPACE and str(step.get("goal", "")) != "":
			get_viewport().set_input_as_handled()
			skip_step()
		elif event.keycode == KEY_DELETE:
			get_viewport().set_input_as_handled()
			_finish()

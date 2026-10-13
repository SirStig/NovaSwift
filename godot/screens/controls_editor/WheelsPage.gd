# NOVA Swift -- Controls Editor "Action Wheels" page: per wheel the trigger button, the clockwise slot list
# (4-12 Flight actions: change, move up/down, remove, add), reset to defaults, the "pause while open" switch and a
# live "unreachable on the pad" warning from ActionWheels.uncovered(). Every control is a plain focusable
# Button / OptionButton / CheckBox, so the d-pad and the PadCursor drive it; the page rebuilds after each edit and
# puts focus back on the control that was used.
extends VBoxContainer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const ActionWheels = preload("res://ActionWheels.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")
const Art = preload("res://screens/controls_editor/ControllerArt.gd")

signal changed

## Buttons offered as a trigger (the Guide button is the OS's).
const TRIGGER_CHOICES := [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_BACK, JOY_BUTTON_START,
	JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK, JOY_BUTTON_X, JOY_BUTTON_Y, JOY_BUTTON_DPAD_UP,
	JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]

var _warn: Label
var _cards: VBoxContainer
var _focus_key := ""
var _style := "xbox"


func setup() -> void:
	add_theme_constant_override("separation", 10)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var s: String = str(Prefs.get_value("input", "ctl_pad_style"))
	_style = s if s in Model.PAD_STYLES else Model.detect_pad_style()
	rebuild()


## Focus the first control (the editor calls this when the tab opens).
func focus_first() -> void:
	var f: Control = find_child("fk_pause", true, false) as Control
	if f != null:
		f.grab_focus()


func rebuild() -> void:
	for c in get_children():
		c.queue_free()
		remove_child(c)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	add_child(top)
	var pause_cb := CheckBox.new()
	pause_cb.name = "fk_pause"
	pause_cb.text = "Pause while a wheel is open"
	pause_cb.button_pressed = ActionWheels.pause_while_open
	pause_cb.focus_mode = Control.FOCUS_ALL
	T.style_text(pause_cb, "body", "regular", T.WHITE)
	pause_cb.toggled.connect(func(on: bool) -> void:
		Prefs.set_value("wheels", "pause", on)
		_focus_key = "fk_pause"
		changed.emit())
	top.add_child(pause_cb)
	NC.hspacer(top)
	var reset: Button = NC.button("Reset wheels to defaults", "bordered", _on_reset, "arrow.counterclockwise")
	reset.name = "fk_reset"
	top.add_child(reset)

	NC.label(self, "Hold a trigger and flick the right stick toward a slot (top slot first, then clockwise); release to use it. "
		+ "A quick tap still does the button's normal action.", "caption", "regular", T.SECONDARY, true)
	_warn = NC.label(self, "", "caption", "semibold", Color(1.0, 0.75, 0.4), true)
	_update_warning()

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 14)
	scroll.add_child(flow)
	for w in ActionWheels.wheels:
		_build_card(flow, w)
	if _focus_key != "":
		var key := _focus_key
		_focus_key = ""
		(func() -> void:
			var f: Control = find_child(key, true, false) as Control
			if f != null:
				f.grab_focus()).call_deferred()


func _update_warning() -> void:
	var miss: Array = ActionWheels.uncovered()
	if miss.is_empty():
		_warn.text = "Every flight action is reachable from the controller."
		_warn.add_theme_color_override("font_color", T.SECONDARY)
	else:
		var names: Array = []
		for a in miss:
			names.append(Model.label_of(str(a)))
		_warn.text = "Unreachable on the pad (no button, in no wheel): " + ", ".join(names)
		_warn.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))


func _commit(focus: String) -> void:
	_focus_key = focus
	ActionWheels.sync()
	Prefs.save()
	changed.emit()
	rebuild()


func _build_card(parent: Node, w: Dictionary) -> void:
	var id: String = str(w["id"])
	var card: PanelContainer = NC.card(parent, 14, 12, true)
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	card.custom_minimum_size = Vector2(400, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	card.add_child(v)
	NC.label(v, str(w["title"]), "heading", "bold", T.AMBER)

	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 8)
	v.add_child(tr)
	NC.label(tr, "Trigger", "caption", "semibold", T.SECONDARY)
	var opts: Array = []
	var names: Array = []
	for b in TRIGGER_CHOICES:
		var other: Dictionary = ActionWheels.wheel_for(int(b))
		var taken: bool = not other.is_empty() and str(other["id"]) != id
		if (ActionWheels.can_trigger(int(b)) and not taken) or int(b) == int(w["trigger"]):
			opts.append(int(b))
			names.append(Art.button_name(_style, int(b)))
	var chip: OptionButton = NC.option_chip(names, maxi(0, opts.find(int(w["trigger"]))), func(i: int) -> void:
		w["trigger"] = int(opts[i])
		w["anchor"] = ActionWheels.default_anchor(int(opts[i]))
		_commit("fk_%s_trigger" % id))
	chip.name = "fk_%s_trigger" % id
	tr.add_child(chip)
	NC.label(tr, "Side", "caption", "semibold", T.SECONDARY)
	var anchor_chip: OptionButton = NC.option_chip(["Left", "Right"], 1 if str(w.get("anchor", "left")) == "right" else 0, func(i: int) -> void:
		w["anchor"] = "right" if i == 1 else "left"
		_commit("fk_%s_anchor" % id))
	anchor_chip.name = "fk_%s_anchor" % id
	tr.add_child(anchor_chip)

	var eligible: Array = []
	for a in Controls.GROUPS["Flight"]:
		if ActionWheels.is_slot_eligible(str(a)):
			eligible.append(str(a))
	var slots: Array = w["slots"]
	for i in slots.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		v.add_child(row)
		var num: Label = NC.label(row, "%d" % (i + 1), "caption", "bold", T.SECONDARY)
		num.custom_minimum_size = Vector2(18, 0)
		var labels: Array = []
		for a in eligible:
			labels.append(Model.label_of(a))
		var sel: OptionButton = NC.option_chip(labels, maxi(0, eligible.find(str(slots[i]))), func(k: int) -> void:
			slots[i] = eligible[k]
			_commit("fk_%s_slot_%d" % [id, i]))
		sel.name = "fk_%s_slot_%d" % [id, i]
		sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sel.clip_text = true
		row.add_child(sel)
		var up: Button = NC.button("Up", "bordered", func() -> void:
			_swap(slots, i, i - 1)
			_commit("fk_%s_up_%d" % [id, maxi(0, i - 1)]))
		up.name = "fk_%s_up_%d" % [id, i]
		up.disabled = i == 0
		row.add_child(up)
		var dn: Button = NC.button("Down", "bordered", func() -> void:
			_swap(slots, i, i + 1)
			_commit("fk_%s_dn_%d" % [id, mini(slots.size() - 1, i + 1)]))
		dn.name = "fk_%s_dn_%d" % [id, i]
		dn.disabled = i == slots.size() - 1
		row.add_child(dn)
		var rm: Button = NC.button("Remove", "bordered", func() -> void:
			slots.remove_at(i)
			_commit("fk_%s_add" % id))
		rm.name = "fk_%s_rm_%d" % [id, i]
		rm.disabled = slots.size() <= ActionWheels.MIN_SLOTS
		row.add_child(rm)
	var add: Button = NC.button("Add slot", "bordered", func() -> void:
		var pick := ""
		for a in eligible:
			if not (a in slots) and not (a as String).begins_with("escort_group_"):
				pick = a
				break
		if pick == "":
			pick = eligible[0]
		slots.append(pick)
		_commit("fk_%s_add" % id))
	add.name = "fk_%s_add" % id
	add.disabled = slots.size() >= ActionWheels.MAX_SLOTS
	v.add_child(add)


static func _swap(arr: Array, a: int, b: int) -> void:
	if a < 0 or b < 0 or a >= arr.size() or b >= arr.size():
		return
	var t: Variant = arr[a]
	arr[a] = arr[b]
	arr[b] = t


func _on_reset() -> void:
	ActionWheels.reset_to_defaults()
	Prefs.set_value("wheels", "pause", true)
	_commit("fk_reset")

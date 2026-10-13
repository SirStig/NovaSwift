# NOVA Swift — the original's Key Settings window (Menu_RunKeySettingsDialog 0x0048b280,
# DLOG/DITL 4002, 594x353), drawn with the Classic UI kit. A port of the Apple app's
# ClassicKeySettingsView; opened from the Preferences window's "Key Settings" button.
#
# The labelled backdrop is PICT 139 (133 on the Mac build); the 34 key cells are DITL items
# 4...37 (81x22), in the three columns the art labels them in. A click selects a cell, the next
# key pressed binds it and the selection steps on (0x0048b6d0). Duplicates are allowed while
# editing; OK is refused (the clashing cell outlined red) while two cells share a key
# (ControlState_FindBindingConflict 0x00466c10). Cancel / Esc discards. "Set Default" only
# previews the defaults (the player still has to press OK). Cells for commands the Godot port has
# no action for stay blank. Rebinds go through Controls.overrides (the table Settings > Controls
# edits too) and persist via Prefs.save(); "More keys..." leads on to that Controls page.
extends CanvasLayer

const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")

## OK or Cancel / Esc / B.
signal closed
## "More keys...": the host shows the NovaSwift Controls page.
signal more_keys
## OK applied new bindings.
signal changed

## Cell order of the art (DITL item 4 + n): Navigation, Battle, Escort, Miscellaneous.
## "" = a cell the art draws but the port has no action for (autopilot, the two spare slots).
const CELLS: Array = [
	"thrust", "reverse", "turn_right", "turn_left", "afterburner", "",
	"hyperspace_arm", "cycle_hyperspace_link", "hyperjump", "clear_target", "hail_target", "land",
	"fire_primary", "fire_secondary", "secondary_next", "clear_secondary", "target_next", "target_nearest_hostile",
	"escort_panel", "escort_attack", "escort_defend", "escort_hold", "escort_formation",
	"pause_menu", "dismiss_message", "board_target", "", "eject", "self_destruct", "toggle_cloak",
	"galaxy_map", "player_info", "mission_info", "",
]
const FIRST_CELL_ITEM := 4
const ITEM_OK := 0
const ITEM_CANCEL := 1
const ITEM_DEFAULT := 2

## Keys the dialog will not capture (NovaInput_PeekActiveCommand skips DIK 2-5, 0x3a-0x3f, 0x70-0x71):
## the number keys 1-4 (the Escort Commands group keys), Caps Lock and F1-F5.
const UNCAPTURABLE: Array = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_CAPSLOCK, KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5]
const BARE_MODIFIERS: Array = [KEY_SHIFT, KEY_ALT, KEY_CTRL, KEY_META]

var dialog: Control
var selected: int = 0
var conflict: int = -1

var _nova: Object
var _host: Control
var _snapshot: Dictionary = {}
var _cells: Array = []        # [{box: ColorRect, label: Label, outline: ReferenceRect}]
var _closing: bool = false


# --- binding model (pure; the self-check drives these without any UI) ----------------------

## Every physical input the action's keyboard binding holds, as "field:code" strings.
static func signatures(action: String) -> Array[String]:
	var out: Array[String] = []
	if action == "" or not Controls.BINDINGS.has(action):
		return out
	var spec: Dictionary = Controls.effective(action)
	for field in ["keys", "alt_keys", "shift_keys"]:
		for code in spec.get(field, []):
			out.append("%s:%d" % [field, int(code)])
	return out


## The cell's text: the action's first key ("Alt+X", "Shift+\\"), blank when unbound.
static func label_for(action: String) -> String:
	if action == "" or not Controls.BINDINGS.has(action):
		return ""
	var spec: Dictionary = Controls.effective(action)
	var keys: Array = spec.get("keys", [])
	var alts: Array = spec.get("alt_keys", [])
	var shifts: Array = spec.get("shift_keys", [])
	if not keys.is_empty():
		return OS.get_keycode_string(int(keys[0]))
	if not alts.is_empty():
		return "Alt+" + OS.get_keycode_string(int(alts[0]))
	if not shifts.is_empty():
		return "Shift+" + OS.get_keycode_string(int(shifts[0]))
	return ""


## KeyBindings.isCapturable for a physical keycode.
static func is_capturable(code: int) -> bool:
	return not (code in UNCAPTURABLE)


## Bind `action` to the single keyboard input (field, code), leaving any other holder alone (0x0048b6d0):
## its other keyboard fields are cleared, pad buttons and analog axes are untouched.
static func assign(action: String, field: String, code: int) -> void:
	if action == "" or not Controls.BINDINGS.has(action):
		return
	var o: Dictionary = Controls.overrides.get(action, {})
	o["keys"] = []
	o["alt_keys"] = []
	o["shift_keys"] = []
	o[field] = [code]
	Controls.overrides[action] = o


## The (field, code) a key press binds: a bare modifier binds itself, Alt+key an Alt chord,
## Shift+key a Shift chord. {} when the event is not a capturable key press.
static func capture_of(event: InputEvent) -> Dictionary:
	if not (event is InputEventKey):
		return {}
	var k: InputEventKey = event
	if not k.pressed or k.echo:
		return {}
	var code: int = int(k.physical_keycode) if int(k.physical_keycode) != 0 else int(k.keycode)
	if code == 0 or code == KEY_ESCAPE or not is_capturable(code):
		return {}
	if code in BARE_MODIFIERS:
		return {"field": "keys", "code": code}
	if k.alt_pressed:
		return {"field": "alt_keys", "code": code}
	if k.shift_pressed:
		return {"field": "shift_keys", "code": code}
	return {"field": "keys", "code": code}


## ControlState_FindBindingConflict: the first CELLS index whose key another cell also holds, or -1.
static func first_conflict() -> int:
	var count: Dictionary = {}
	for a in CELLS:
		for s in signatures(str(a)):
			count[s] = int(count.get(s, 0)) + 1
	for i in CELLS.size():
		for s in signatures(str(CELLS[i])):
			if int(count.get(s, 0)) > 1:
				return i
	return -1


# --- window --------------------------------------------------------------------------------

func setup(nova: Object) -> void:
	_nova = nova
	layer = 80
	ClassicTheme.setup(nova)
	_snapshot = Controls.overrides.duplicate(true)
	_build()


func _build() -> void:
	var me := self
	var custom: Dictionary = {}
	for c in CELLS.size():
		custom[FIRST_CELL_ITEM + c] = func(parent: Control, rect: Rect2i): me._add_cell(parent, rect, c)
	var frame: int = 139 if ClassicTheme.pict(139) != null else 133
	dialog = ClassicDialog.from_ditl(_nova, 4002, {
		"frame_pict": frame if ClassicTheme.pict(frame) != null else -1,
		"fallback_size": Vector2i(594, 353), "custom": custom,
		"actions": {ITEM_OK: me._ok, ITEM_CANCEL: me._cancel, ITEM_DEFAULT: me._set_default},
		"default_item": ITEM_OK, "cancel_item": ITEM_CANCEL})
	_host = ClassicDialog.modal(self, dialog, 0.55)
	var more := Button.new()
	more.text = "More keys…"
	more.flat = true
	more.modulate = Color(1, 1, 1, 0.7)
	more.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	more.position = Vector2(-50, -40)
	more.pressed.connect(func(): me._more())
	_host.add_child(more)
	_refresh()


func _add_cell(parent: Control, rect: Rect2i, n: int) -> void:
	var box := ColorRect.new()
	box.color = Color(0, 0, 0, 0)
	box.position = Vector2(rect.position)
	box.size = Vector2(rect.size)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			select_cell(n))
	var l := Label.new()
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", ClassicTheme.body_font())
	l.add_theme_font_size_override("font_size", 12)
	box.add_child(l)
	var ring := ReferenceRect.new()
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.border_color = Color.RED
	ring.border_width = 2.0
	ring.editor_only = false
	ring.visible = false
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ring)
	parent.add_child(box)
	while _cells.size() <= n:
		_cells.append({})
	_cells[n] = {"box": box, "label": l, "outline": ring}


func select_cell(n: int) -> void:
	selected = clampi(n, 0, CELLS.size() - 1)
	conflict = -1
	_refresh()


## Paint the labels, the selected cell (inverted) and the conflict outline.
func _refresh() -> void:
	for n in _cells.size():
		var c: Dictionary = _cells[n]
		if c.is_empty():
			continue
		var label: Label = c["label"]
		var box: ColorRect = c["box"]
		var ring: ReferenceRect = c["outline"]
		label.text = label_for(str(CELLS[n]))
		var sel: bool = (n == selected)
		box.color = Color.BLACK if sel else Color(0, 0, 0, 0)
		label.add_theme_color_override("font_color", Color.WHITE if sel else Color.BLACK)
		ring.visible = (n == conflict)


## Bind the captured key to the selected cell and step on (blank cells are skipped over).
func capture(field: String, code: int) -> void:
	var action: String = str(CELLS[selected])
	if action == "":
		selected = (selected + 1) % CELLS.size()
		_refresh()
		return
	assign(action, field, code)
	conflict = -1
	selected = (selected + 1) % CELLS.size()
	_refresh()


func _input(event: InputEvent) -> void:
	var cap: Dictionary = capture_of(event)
	if cap.is_empty():
		return
	get_viewport().set_input_as_handled()
	capture(str(cap["field"]), int(cap["code"]))


func _ok() -> void:
	var clash: int = first_conflict()
	if clash >= 0:
		conflict = clash
		selected = clash
		_refresh()
		return
	Prefs.save()
	Controls.register()
	changed.emit()
	_close()


func _cancel() -> void:
	Controls.overrides = _snapshot.duplicate(true)
	_close()


## Set Default only previews the defaults (the original's overrides are cleared in the draft).
func _set_default() -> void:
	Controls.overrides = {}
	conflict = -1
	_refresh()


func _more() -> void:
	Controls.overrides = _snapshot.duplicate(true)
	more_keys.emit()
	_close()


func _close() -> void:
	if _closing:
		return
	_closing = true
	closed.emit()
	queue_free()

# NOVA Swift — Classic UI kit: shared look + asset cache.
#
# The authentic EV Nova interface, built from the player's own data (the same
# resources the Apple app's SpaceportGraphics / NovaUITheme read): PICT frames,
# the three-state button art (PICT 7500…), the `cölr` palette and the `ïntf`
# status bar. Everything is fetched through the NovaWorld bridge ("Classic UI"
# section + pict_info/pict_rgba) and cached here as Godot textures.
#
# Fonts: the original's Charcoal / Geneva / Chicago are Apple's and not shipped.
# Like the Apple app we substitute the bundled OFL lookalikes: Rubik for Charcoal
# (button + title chrome), Arimo for Geneva / Chicago (body, HUD, native dialogs).
#
# Loaded with preload() (no class_name), like Controls.gd. State is static; call
# reset() when a different data folder is loaded.
extends RefCounted

const Prefs = preload("res://Prefs.gd")

const RUBIK := preload("res://ui/classic/fonts/Rubik.ttf")
const ARIMO := preload("res://ui/classic/fonts/Arimo.ttf")

## Native-dialog greys (ClassicUiWindow): QuickDraw 16-bit greys / 65535.
const NATIVE_FILL := Color(0.534, 0.534, 0.534)       # 35000
const NATIVE_LIGHT := Color(0.763, 0.763, 0.763)      # 50000
const NATIVE_DARK := Color(0.229, 0.229, 0.229)       # 15000
const NATIVE_PRESSED := Color(0.381, 0.381, 0.381)    # 25000
## Keyboard / gamepad focus highlight on the original art (amber, like the app icon).
const FOCUS := Color(1.0, 0.78, 0.35)

## True while the LAST input was keyboard navigation or a gamepad (false after any
## mouse / touch input). The original has no hover or focus outline at all, so the
## kit draws its focus indication (Apple's controller-cursor "hover-grow", the
## original's dotted default ring, the list highlight) ONLY while this is true.
static var nav_active := false
static var _tracker: Node
static var _tracker_pending := false

static var _nova: Object
static var _palette := {}
static var _tex := {}        # pict id -> ImageTexture (or null)
static var _btn := {}        # Vector2i(width, state) -> ImageTexture
static var _loaded := false


## Bind to a NovaWorld that has the game loaded.
static func setup(nova: Object) -> void:
	if _nova != nova:
		reset()
	_nova = nova
	_refresh_tc_fonts()


static func reset() -> void:
	_nova = null
	_palette = {}
	_tex = {}
	_btn = {}
	_loaded = false


static func nova() -> Object:
	return _nova


static func has_data() -> bool:
	return _nova != null and _nova.has_game()


# --- last input device (focus indication) -----------------------------------------

## Tracks the last input device. One instance lives under the scene-tree root.
class NavTracker extends Node:
	signal changed(active: bool)
	var handler: Callable

	func _input(event: InputEvent) -> void:
		handler.call(event)


const _NAV_ACTIONS := ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_focus_next", "ui_focus_prev"]


## Make sure the tracker exists and is in the tree (call from any control's
## `_enter_tree`; idempotent).
static func track(from: Node) -> void:
	if _tracker == null or not is_instance_valid(_tracker):
		_tracker = NavTracker.new()
		_tracker.name = "ClassicNavTracker"
		_tracker.handler = note_event
		_tracker_pending = false
	if from == null or not from.is_inside_tree():
		return
	if not _tracker.is_inside_tree() and not _tracker_pending:
		_tracker_pending = true
		from.get_tree().root.add_child.call_deferred(_tracker)


## Fold one input event into `nav_active` (the tracker calls this; tests may too).
static func note_event(event: InputEvent) -> void:
	var want := nav_active
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch \
			or event is InputEventScreenDrag:
		want = false
	elif event is InputEventKey:
		if event.pressed:
			for a in _NAV_ACTIONS:
				if event.is_action_pressed(a):
					want = true
					break
	elif event is InputEventJoypadButton:
		if event.pressed:
			want = true
	elif event is InputEventJoypadMotion:
		if absf(event.axis_value) > 0.5:
			want = true
	set_nav_active(want)


static func set_nav_active(on: bool) -> void:
	if on == nav_active:
		return
	nav_active = on
	if _tracker != null and is_instance_valid(_tracker):
		_tracker.changed.emit(on)


## Call `cb(active: bool)` whenever the input device flips between mouse and keyboard/pad.
## Needs `track()` to have run; the connection dies with the callable's object.
static func on_nav_changed(cb: Callable) -> void:
	if _tracker == null or not is_instance_valid(_tracker):
		return
	if not _tracker.changed.is_connected(cb):
		_tracker.changed.connect(cb)


## Should a focused control draw its focus indication right now? The control under the gamepad UI pointer
## (ui/PadCursor.gd) draws it too, without taking focus: focus_entered handlers select rows, switch tabs and
## start editing fields, and hovering must never click anything.
static func show_focus(c: Control) -> bool:
	return nav_active and (c.has_focus() or is_same(c, pad_hover))


## The control under the gamepad UI pointer, or null (a Variant: it may be freed under the pointer).
static var pad_hover: Variant = null


static func set_pad_hover(c: Control) -> void:
	if is_same(c, pad_hover):
		return
	var old: Variant = pad_hover
	pad_hover = c
	for x: Variant in [old, c]:
		if x == null or not is_instance_valid(x):
			continue
		var ctl: Control = x
		if ctl.has_method("_sync_focus"):
			ctl.call("_sync_focus")
		elif ctl.has_method("_sync"):
			ctl.call("_sync")
		ctl.queue_redraw()


# --- fonts ---------------------------------------------------------------------

## The font for an original font name (cölr / ïntf): Charcoal -> Rubik, else Arimo. A font file the
## selected total conversion ships (EV Classic / EV Override: Sillycon.ttf, named "Sillycon Plain" by
## their ïntf) wins when its family or file name matches.
static func font_for(original_name: String) -> Font:
	var key: String = original_name.strip_edges().to_lower()
	if _tc_fonts.has(key):
		return _tc_fonts[key]
	return RUBIK if key == "charcoal" else ARIMO


## Fonts registered from the conversion's folders: lower-case family / "family style" / file stem -> Font.
static var _tc_fonts: Dictionary = {}
static var _tc_fonts_sig: String = ""


## (Re)register the selected conversion's font files (NovaPlugins.font_files); cheap when unchanged.
static func _refresh_tc_fonts() -> void:
	if _nova == null or not ClassDB.class_exists("NovaPlugins"):
		return
	var pl: Object = ClassDB.instantiate("NovaPlugins")
	if pl == null or not pl.has_method("font_files"):
		return
	var sig: String = str(pl.font_files())
	if sig == _tc_fonts_sig:
		return
	_tc_fonts_sig = sig
	_tc_fonts = {}
	var arr: Variant = JSON.parse_string(sig)
	if not (arr is Array):
		return
	for p in arr:
		var path: String = str(p)
		var ff := FontFile.new()
		if ff.load_dynamic_font(path) != OK:
			continue
		var fam: String = ff.get_font_name().strip_edges().to_lower()
		var style: String = ff.get_font_style_name().strip_edges().to_lower()
		for k in [fam, (fam + " " + style).strip_edges(), path.get_file().get_basename().to_lower()]:
			if str(k) != "":
				_tc_fonts[str(k)] = ff


static func body_font() -> Font:
	return ARIMO


static func chrome_font() -> Font:
	return RUBIK


## Shrink-to-fit (Apple NovaText `shrinkToFit`: one line, minimumScaleFactor 0.5): the
## largest whole-pixel size <= `nominal` at which `text` fits `width`, never below half the
## nominal. The classic kit never ellipsizes; only below that floor does the label clip.
static func fit_size(font: Font, text: String, width: float, nominal: int) -> int:
	var floor_px := maxi(1, int(ceil(nominal * 0.5)))
	var s := nominal
	while s > floor_px and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x > width:
		s -= 1
	return s


## Set `l.text` and the font size that makes it fit `width` (see fit_size).
static func fit_label(l: Label, text: String, width: float, nominal: int) -> void:
	l.text = text
	l.add_theme_font_size_override("font_size", fit_size(l.get_theme_font("font"), text, width, nominal))


# --- cölr palette ---------------------------------------------------------------

## The cölr palette: Color values keyed buttonUp, buttonDown, buttonGrey, gridBright,
## gridDim, listText, listBkgnd, listHilite, progBright, progDim, progOutline,
## floatingMap, escortHilite, menuColor1, menuColor2; plus buttonFont (String) and
## buttonFontSize (int). Pure-black decodes fall back like NovaUITheme.
static func palette() -> Dictionary:
	if _loaded:
		return _palette
	_loaded = true
	_palette = {
		"buttonUp": Color.WHITE, "buttonDown": Color(0.5, 0.5, 0.5), "buttonGrey": Color(0.15, 0.15, 0.15),
		"gridBright": Color(1, 0, 0), "gridDim": Color(0.25, 0.25, 0.25),
		"listText": Color.WHITE, "listBkgnd": Color(0, 0, 0, 0), "listHilite": Color(1, 1, 1, 0.14),
		"progBright": Color(1.0, 0.72, 0.28), "progDim": Color(0.05, 0.05, 0.05), "progOutline": Color(0.3, 0.3, 0.3),
		"floatingMap": Color(1.0, 0.72, 0.28, 0.25), "escortHilite": Color(1.0, 0.72, 0.28, 0.16),
		"menuColor1": Color(1, 0, 0), "menuColor2": Color(0.5, 0, 0),
		"buttonFont": "Charcoal", "buttonFontSize": 12,
	}
	if _nova == null:
		return _palette
	var parsed = JSON.parse_string(_nova.classic_colors())
	if not (parsed is Dictionary):
		return _palette
	for key in parsed:
		var v = parsed[key]
		if v is String and v.begins_with("#"):
			var c := Color.html(v)
			# listBkgnd is legitimately black: leave it clear so the frame shows.
			if c.r + c.g + c.b > 0.0 and key != "listBkgnd":
				_palette[key] = c
		elif key == "buttonFont" and v is String and v != "":
			_palette[key] = v
		elif key == "buttonFontSize" and int(v) > 0:
			_palette[key] = int(v)
	return _palette


static func color(key: String) -> Color:
	return palette().get(key, Color.WHITE)


# --- textures --------------------------------------------------------------------

## A PICT as a Texture2D (cached), or null when absent. Nearest-filtered by the
## owning CanvasItem (the kit sets texture_filter on every root it builds).
static func pict(id: int) -> Texture2D:
	if _tex.has(id):
		return _tex[id]
	var t: Texture2D = null
	if _nova != null:
		var info: PackedInt32Array = _nova.pict_info(id)
		if info.size() >= 2 and info[0] > 0 and info[1] > 0:
			var img := Image.create_from_data(info[0], info[1], false, Image.FORMAT_RGBA8, _nova.pict_rgba(id))
			t = ImageTexture.create_from_image(img)
	_tex[id] = t
	return t


## The composed three-state button `width` px wide (state 0 normal, 1 pressed,
## 2 grey): left cap, stretched middle, right cap — no label.
static func button_texture(width: int, state: int) -> Texture2D:
	var key := Vector2i(width, state)
	if _btn.has(key):
		return _btn[key]
	var t: Texture2D = null
	if _nova != null:
		var h: int = _nova.classic_button_height()
		var bytes: PackedByteArray = _nova.classic_button_rgba(width, state)
		if bytes.size() == width * h * 4 and width > 0:
			t = ImageTexture.create_from_image(Image.create_from_data(width, h, false, Image.FORMAT_RGBA8, bytes))
	_btn[key] = t
	return t


static func button_height() -> int:
	return _nova.classic_button_height() if _nova != null else 25


## A STR# entry (1-based, as the game counts), or `fallback`.
static func string_at(list_id: int, index1: int, fallback := "") -> String:
	if _nova == null:
		return fallback
	var all: PackedStringArray = _nova.classic_strings(list_id)
	return all[index1 - 1] if index1 >= 1 and index1 <= all.size() and all[index1 - 1] != "" else fallback


# --- presentation setting --------------------------------------------------------

## True when the screen kind should use the authentic UI: data is loaded and the
## matching Prefs flag is off. `kind`: "dialogs" | "hud" | "menu".
static func classic(kind: String) -> bool:
	return has_data() and not bool(Prefs.get_value("presentation", "modern_" + kind))

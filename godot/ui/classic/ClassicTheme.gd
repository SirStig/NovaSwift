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


# --- fonts ---------------------------------------------------------------------

## The font for an original font name (cölr / ïntf): Charcoal -> Rubik, else Arimo.
static func font_for(original_name: String) -> Font:
	return RUBIK if original_name.strip_edges().to_lower() == "charcoal" else ARIMO


static func body_font() -> Font:
	return ARIMO


static func chrome_font() -> Font:
	return RUBIK


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

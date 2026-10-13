# NOVA Swift — Classic UI kit: the authentic in-flight status bar.
#
# The original `ïntf` status bar from the player's data (the Apple app's
# AuthenticHUDView): the backdrop PICT (700 in the base game, per-government
# `ïntf`) anchored to the right edge and scaled to the viewport height, with the
# radar, shield / armor / fuel bars at the exact ïntf rectangles and colours, the
# target box, secondary weapon, nav readout and cargo/credits text in the ïntf
# fonts and bright/dim text colours.
#
#   var hud = AuthenticHUD.new()        # a full-rect Control, mouse-transparent
#   hud.setup(nova)                      # reads classic_* bridge calls each frame
#   hud.active = func(): return not in_menu and not nova.is_landed()
#   canvas_layer.add_child(hud)
#
# Main.gd instantiates it when Prefs presentation/modern_hud is false and skips its
# primitive HUD. Draws in screen space (rects x scale, fonts at scaled size) so the
# text stays sharp; the backdrop uses nearest filtering at integer-ish scales and
# linear below 1x. Not yet shown (bridge doesn't expose them): the target ship
# silhouette, shïp subtitle / govt code, IFF contact colours, per-commodity cargo
# rows, radar static.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends Control

const Theme_ := preload("res://ui/classic/ClassicTheme.gd")

const RADAR_WORLD_RANGE := 4500.0   # the Apple app's client-side radarRange

var nova: Object
## Optional Callable() -> bool; when set, the HUD hides while it returns false.
var active: Callable = Callable()

var _intf := {}
var _intf_id := -1
var _backdrop: Texture2D
var _ship_type := -2
var _font: Font
var _scale := 1.0
var _origin_x := 0.0


func setup(nova_obj: Object) -> void:
	nova = nova_obj
	Theme_.setup(nova)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reload()


## Rebuild from the interface for the player's current hull.
func _reload() -> void:
	_ship_type = nova.player_ship_type() if nova != null else -1
	var id: int = nova.classic_interface_id(_ship_type) if _ship_type >= 0 else 128
	if id == _intf_id and not _intf.is_empty():
		return
	_intf_id = id
	var parsed = JSON.parse_string(nova.classic_interface(id))
	_intf = parsed if parsed is Dictionary else {}
	_backdrop = Theme_.pict(int(_intf.get("bgPict", 128))) if not _intf.is_empty() else null
	_font = Theme_.font_for(str(_intf.get("font", "Geneva")))


## True when the data supplied an ïntf + backdrop (otherwise Main keeps its HUD).
func is_ready() -> bool:
	return not _intf.is_empty() and _backdrop != null


func _process(_dt: float) -> void:
	var on := nova != null and is_ready() and (not active.is_valid() or bool(active.call()))
	if visible != on:
		visible = on
	if on:
		if nova.player_ship_type() != _ship_type:
			_reload()
		queue_redraw()


# --- geometry -------------------------------------------------------------------------

func _rect(key: String) -> Rect2:
	var r: Array = _intf[key]
	return Rect2(_origin_x + r[0] * _scale, r[1] * _scale, (r[2] - r[0]) * _scale, (r[3] - r[1]) * _scale)


func _col(key: String) -> Color:
	return Color.html(str(_intf.get(key, "#ffffff")))


func _fs(design_size: int) -> int:
	return maxi(6, int(round(float(design_size) * _scale)))


func _draw() -> void:
	if not is_ready():
		return
	var bg_w := float(_intf["bgW"])
	var bg_h := float(_intf["bgH"])
	_scale = size.y / bg_h
	_origin_x = size.x - bg_w * _scale
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if _scale >= 1.0 else CanvasItem.TEXTURE_FILTER_LINEAR
	draw_texture_rect(_backdrop, Rect2(_origin_x, 0, bg_w * _scale, size.y), false)

	_draw_bar("shield", float(nova.player_shield_fraction()), "shieldColor")
	_draw_bar("armor", float(nova.player_armor_fraction()), "armorColor")
	_draw_fuel()
	_draw_radar()
	_draw_target()
	_draw_weapon()
	_draw_nav()
	_draw_cargo()


# --- bars -------------------------------------------------------------------------------

func _segment(key: String, a: float, b: float) -> Rect2:
	var r: Array = _intf[key]
	var seg: PackedInt32Array = nova.classic_bar_segment(int(r[0]), int(r[1]), int(r[2] - r[0]), int(r[3] - r[1]), a, b)
	return Rect2(_origin_x + seg[0] * _scale, seg[1] * _scale, seg[2] * _scale, seg[3] * _scale)


func _draw_bar(key: String, value: float, color_key: String) -> void:
	draw_rect(_segment(key, 0.0, clampf(value, 0.0, 1.0)), _col(color_key))


## The jump meter: whole hyperjumps in fuelFull, the leftover in fuelPartial.
func _draw_fuel() -> void:
	var f: PackedFloat64Array = nova.classic_fuel_bar()
	if f[0] > 0.0:
		draw_rect(_segment("fuel", 0.0, f[0]), _col("fuelFull"))
	if f[1] > 0.0:
		draw_rect(_segment("fuel", f[0], f[0] + f[1]), _col("fuelPartial"))


# --- radar --------------------------------------------------------------------------------

func _draw_radar() -> void:
	var rr := _rect("radar")
	var c := rr.get_center()
	var radius := minf(rr.size.x, rr.size.y) / 2.0 - 2.0 * _scale
	var sensor: float = nova.effective_sensor_range(RADAR_WORLD_RANGE)
	if sensor <= 0.0:
		sensor = RADAR_WORLD_RANGE
	var k := radius / sensor
	var dim := _col("radarDim")
	var bright := _col("radarBright")
	var pw: Vector2 = nova.player_position()
	var blink := int(Time.get_ticks_msec() / 250) % 2 == 0

	# Stellars: hollow rings (the original draws worlds as circles).
	var bodies: PackedFloat32Array = nova.body_transforms()
	var i := 0
	while i + 3 < bodies.size():
		var off := Vector2(bodies[i] - pw.x, -(bodies[i + 1] - pw.y)) * k
		if off.length() <= radius:
			var d := clampf(bodies[i + 2] * k * 2.0, 5.0 * _scale, 14.0 * _scale)
			draw_arc(c + off, d / 2.0, 0.0, TAU, 20, dim, maxf(1.0, _scale), true)
		i += 4

	# Ships: small dots; the target alone blinks BrightRadar (no IFF).
	var xf: PackedFloat32Array = nova.ship_transforms()
	var ids: PackedInt32Array = nova.ship_ids()
	var target: int = nova.player_target_id()
	var n := 0
	var j := 0
	while j + 3 < xf.size():
		if n > 0:
			var off := Vector2(xf[j] - pw.x, -(xf[j + 1] - pw.y)) * k
			if off.length() <= radius:
				var is_target := n < ids.size() and ids[n] == target and target >= 0
				var side := maxf(2.0, 2.0 * _scale)
				var col := bright if (is_target and blink) else dim
				draw_rect(Rect2(c + off - Vector2(side, side) / 2.0, Vector2(side, side)), col)
		j += 4
		n += 1

	# The player's arrow at the centre, nose along the heading.
	var a: float = nova.player_angle()
	var dir := Vector2(sin(a), -cos(a))
	var side_v := Vector2(dir.y, -dir.x)
	var s := _scale
	draw_colored_polygon(PackedVector2Array([
		c + dir * 6.0 * s, c - dir * 4.0 * s + side_v * 4.0 * s, c - dir * 2.0 * s, c - dir * 4.0 * s - side_v * 4.0 * s]), bright)


# --- text readouts ---------------------------------------------------------------------------

## Draw `text` centred in `area` at design font size `size_d`, shrunk (down to 55%)
## when it is wider than the area, baseline at `y` (screen px).
func _text_c(text: String, area: Rect2, y: float, size_d: int, color: Color) -> void:
	var fs := _fs(size_d)
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var avail := area.size.x - 4.0 * _scale
	if w > avail and w > 0.0:
		fs = maxi(6, int(floor(fs * maxf(0.55, avail / w))))
		w = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(roundf(area.position.x + (area.size.x - w) / 2.0), roundf(y)), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func _line_h(size_d: int) -> float:
	return float(_fs(size_d)) * 1.2


func _asc(size_d: int) -> float:
	return _font.get_ascent(_fs(size_d))


func _draw_target() -> void:
	var a := _rect("target")
	var st := int(_intf["fontSize"])
	var sub := int(_intf["subtitleSize"])
	var bright := _col("bright")
	var dim := _col("dim")
	var tid: int = nova.player_target_id()
	if tid < 0:
		_text_c("No Target", a, a.position.y + a.size.y / 2.0, sub, dim)
		return
	var y := a.position.y + 4.0 * _scale + _asc(st)
	_text_c(nova.target_name(), a, y, st, bright)
	# Bottom row: Shield: N % (or Armor once the shields are down).
	var sh := int(round(nova.target_shield_fraction() * 100.0))
	var ar := int(round(nova.target_armor_fraction() * 100.0))
	var label := "Shield:" if sh > 0 else "Armor:"
	var value := "%d %%" % (sh if sh > 0 else ar)
	var by := a.end.y - 4.0 * _scale - _font.get_descent(_fs(sub))
	var fs := _fs(sub)
	draw_string(_font, Vector2(roundf(a.position.x + 6.0 * _scale), roundf(by)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim)
	var lw := _font.get_string_size(label + " ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(roundf(a.position.x + 6.0 * _scale + lw), roundf(by)), value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, bright)


func _draw_weapon() -> void:
	var a := _rect("weapon")
	var st := int(_intf["fontSize"])
	var sub := int(_intf["subtitleSize"])
	var mid := a.position.y + a.size.y / 2.0
	var name_: String = nova.secondary_weapon_name() if nova.has_secondary_weapon() else ""
	if name_ == "":
		_text_c("No Secondary Weapon", a, mid + _asc(sub) / 2.0, sub, _col("dim"))
		return
	var ammo: int = nova.secondary_weapon_ammo()
	var label := "%s - %d" % [name_, ammo] if ammo >= 0 else name_
	_text_c(label, a, mid + _asc(st) / 2.0, st, _col("bright"))


func _draw_nav() -> void:
	var a := _rect("nav")
	var st := int(_intf["fontSize"])
	var sub := int(_intf["subtitleSize"])
	var rd: PackedStringArray = nova.nav_readout()
	if rd.size() < 3 or rd[0] == "":
		_text_c("No Destination", a, a.position.y + a.size.y / 2.0 + _asc(sub) / 2.0, sub, _col("dim"))
		return
	# Title (dim) over the selected stellar / armed next hop (bright; dim until jumpable).
	var y1 := a.position.y + 4.0 * _scale + _asc(sub)
	_text_c(rd[0], a, y1, sub, _col("dim"))
	if rd[1] != "":
		var y2 := y1 + _line_h(st)
		_text_c(rd[1], a, y2, st, _col("dim") if rd[2] == "1" else _col("bright"))


func _draw_cargo() -> void:
	var a := _rect("cargo")
	var st := int(_intf["fontSize"])
	var sub := int(_intf["subtitleSize"])
	var dim := _col("dim")
	var bright := _col("bright")
	var y := a.position.y + 6.0 * _scale + _asc(sub)
	_free_row(a, y, sub, st, dim, bright)
	y += _line_h(st) + 6.0 * _scale
	_text_c("Credits:", a, y, sub, dim)
	_text_c(credits_hud(int(nova.player_credits())), a, y + _line_h(st), st, bright)


func _free_row(a: Rect2, y: float, sub: int, st: int, dim: Color, bright: Color) -> void:
	var fs_l := _fs(sub)
	var fs_v := _fs(st)
	var free_s := str(maxi(0, int(nova.cargo_free_tons())))
	var lw := _font.get_string_size("Free: ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_l).x
	var vw := _font.get_string_size(free_s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_v).x
	var x := roundf(a.position.x + (a.size.x - lw - vw) / 2.0)
	draw_string(_font, Vector2(x, roundf(y)), "Free:", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_l, dim)
	draw_string(_font, Vector2(x + lw, roundf(y)), free_s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_v, bright)


## The status bar's credits figure (FUN_00465af0): plain below 1,000; "N,NNN"
## below a million; else "N.NNM" with the hundredths truncated.
static func credits_hud(n: int) -> String:
	if n < 1000:
		return str(n)
	if n < 1000000:
		return "%d,%03d" % [n / 1000, n % 1000]
	return "%d.%02dM" % [n / 1000000, (n % 1000000) / 10000]

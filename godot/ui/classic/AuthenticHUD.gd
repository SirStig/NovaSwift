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
# linear below 1x. Also drawn, as the Apple AuthenticHUDView does: the target's red ship
# silhouette, its shïp subtitle and status / govt-code row, IFF contact colours (with an IFF
# outfit), per-commodity cargo rows + Special, and radar interference static.
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
var _sil: TextureRect               # the target silhouette (grey x red tint shader)
var _sil_cache := {}                # ship type -> AtlasTexture (or null)
var _target := {}                   # hud_target_info JSON, refreshed ~12 Hz
var _cargo := {}                    # hud_cargo_panel JSON
var _has_iff := false
var _static_on := false
var _static_clock := 0.0
var _poll_clock := 1.0


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


func _process(dt: float) -> void:
	var on := nova != null and is_ready() and (not active.is_valid() or bool(active.call()))
	if visible != on:
		visible = on
	if on:
		if nova.player_ship_type() != _ship_type:
			_reload()
		_poll(dt)
		queue_redraw()


## The slow-changing readouts (target text, cargo panel, IFF) at ~12 Hz, and the radar's
## interference roll: each refresh, at most every 250 ms, may show only static (OS-05).
func _poll(dt: float) -> void:
	_poll_clock += dt
	if _poll_clock >= 0.08:
		_poll_clock = 0.0
		var t = JSON.parse_string(nova.hud_target_info())
		_target = t if t is Dictionary else {}
		var c = JSON.parse_string(nova.hud_cargo_panel())
		_cargo = c if c is Dictionary else {}
		_has_iff = nova.hud_has_iff()
	_static_clock += dt
	if _static_clock >= 0.25:
		_static_clock = 0.0
		_static_on = randi() % 100 < int(nova.radar_static_chance())


## Width the bar claims on the right of a `vp` window (Apple sidebarWidth: capped at 35 %).
func bar_width(vp: Vector2) -> float:
	if _intf.is_empty() or float(_intf.get("bgH", 0)) <= 0.0:
		return 0.0
	return minf(float(_intf["bgW"]) * vp.y / float(_intf["bgH"]), vp.x * 0.35)


## The ïntf text face for the message log / prompts the host draws in the play area.
func text_font() -> Font:
	return _font


func text_size() -> int:
	return int(_intf.get("fontSize", 12))


func bright_color() -> Color:
	return _col("bright")


func dim_color() -> Color:
	return _col("dim")


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
	var dim := _col("radarDim")
	var bright := _col("radarBright")
	# With an IFF the scope is filled black first (0x0045d0a0); without one the PICT shows through.
	if _has_iff:
		draw_circle(c, radius + 2.0 * _scale, Color.BLACK)
	# Interference: this refresh shows only noise over the scope, no contacts.
	if _static_on:
		for i in int(rr.size.x * rr.size.y / (12.0 * _scale * _scale)):
			var q := rr.position + Vector2(randf() * rr.size.x, randf() * rr.size.y)
			if q.distance_to(c) <= radius:
				draw_rect(Rect2(q, Vector2(_scale, _scale)), dim)
		return
	var sensor: float = nova.effective_sensor_range(RADAR_WORLD_RANGE)
	if sensor <= 0.0:
		sensor = RADAR_WORLD_RANGE
	var k := radius / sensor
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

	# Ships: small dots. Without an IFF every contact is DimRadar and only the target blinks
	# BrightRadar (OS-05); with one, Ship_GetShipRadarColor's classes (grey hulk / red threat /
	# green squad / blue other) and the target alternates its class colour with BrightRadar.
	var xf: PackedFloat32Array = nova.ship_transforms()
	var ids: PackedInt32Array = nova.ship_ids()
	var iff: PackedInt32Array = nova.ship_iff_classes() if _has_iff else PackedInt32Array()
	var target: int = nova.player_target_id()
	var n := 0
	var j := 0
	while j + 3 < xf.size():
		if n > 0:
			var off := Vector2(xf[j] - pw.x, -(xf[j + 1] - pw.y)) * k
			if off.length() <= radius:
				var is_target := n < ids.size() and ids[n] == target and target >= 0
				var side := maxf(2.0, 2.0 * _scale)
				var col := dim
				if _has_iff and n < iff.size():
					col = iff_color(iff[n])
					if is_target and blink:
						col = bright
				elif is_target and blink:
					col = bright
				draw_rect(Rect2(c + off - Vector2(side, side) / 2.0, Vector2(side, side)), col)
		j += 4
		n += 1

	# The player's arrow at the centre, nose along the heading (cyan with an IFF).
	var a: float = nova.player_angle()
	var dir := Vector2(sin(a), -cos(a))
	var side_v := Vector2(dir.y, -dir.x)
	var s := _scale
	draw_colored_polygon(PackedVector2Array([
		c + dir * 6.0 * s, c - dir * 4.0 * s + side_v * 4.0 * s, c - dir * 2.0 * s, c - dir * 4.0 * s - side_v * 4.0 * s]),
		Color(0, 1, 1) if _has_iff else bright)


## The IFF colours of `Ship_GetShipRadarColor` 0x00465f00 (class from `ship_iff_classes`).
static func iff_color(cls: int) -> Color:
	match cls:
		0: return Color(0.25, 0.25, 0.25)
		1: return Color(1, 0, 0)
		2: return Color(0, 1, 0)
		_: return Color(0, 0, 1)


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
	if _target.is_empty() or nova.player_target_id() < 0:
		if _sil != null:
			_sil.visible = false
		_text_c(Theme_.string_at(2002, 349, "No Target"), a, a.position.y + a.size.y / 2.0, sub, dim)
		return
	# Name (bright) and the hull's subtitle (dim) up top...
	var y := a.position.y + 4.0 * _scale + _asc(st)
	_text_c(str(_target["name"]), a, y, st, bright)
	var sub_h := 0.0
	if str(_target["subtitle"]) != "":
		y += _line_h(st) * 0.9
		_text_c(str(_target["subtitle"]), a, y, sub, dim)
		sub_h = _line_h(sub)
	# ...the status row beneath the picture: "Shield: N %" (or Shields Down / Disabled) left, the
	# govt TargetCode right; hulls that hide the line show only the code, centred.
	var fs := _fs(sub)
	var by := a.end.y - 4.0 * _scale - _font.get_descent(fs)
	var code := str(_target["code"])
	if bool(_target["hidesLine"]):
		_text_c(code, a, by, sub, dim)
	else:
		var x := roundf(a.position.x + 6.0 * _scale)
		var label := str(_target["statusLabel"])
		if label != "":
			draw_string(_font, Vector2(x, roundf(by)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim)
			x += _font.get_string_size(label + " ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(_font, Vector2(x, roundf(by)), str(_target["statusValue"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, bright)
		if code != "":
			var cw := _font.get_string_size(code, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(_font, Vector2(roundf(a.end.x - 6.0 * _scale - cw), roundf(by)), code,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim)
	# The silhouette claims the space between, kept square.
	var top := y + 4.0 * _scale + (0.0 if sub_h == 0.0 else 0.0)
	var free := Rect2(a.position.x + 6.0 * _scale, top, a.size.x - 12.0 * _scale, by - _asc(sub) - top - 2.0 * _scale)
	_place_silhouette(int(_target["shipType"]), free)


## EV Nova draws the target in red, shaded by the sprite's own luminance (a grey x tint shader).
func _place_silhouette(ship_type: int, free: Rect2) -> void:
	if _sil == null:
		_sil = TextureRect.new()
		_sil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sil.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_sil.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var sh := Shader.new()
		sh.code = "shader_type canvas_item;\nuniform vec4 tint : source_color = vec4(0.85, 0.34, 0.28, 1.0);\nvoid fragment() { vec4 c = texture(TEXTURE, UV); float g = dot(c.rgb, vec3(0.299, 0.587, 0.114)); COLOR = vec4(vec3(g) * tint.rgb, c.a); }"
		var mat := ShaderMaterial.new()
		mat.shader = sh
		_sil.material = mat
		add_child(_sil)
	var tex: Texture2D = _silhouette_tex(ship_type)
	_sil.visible = tex != null and free.size.x > 4.0 and free.size.y > 4.0
	if not _sil.visible:
		return
	_sil.texture = tex
	var side := minf(free.size.x, free.size.y)
	_sil.position = free.position + (free.size - Vector2(side, side)) / 2.0
	_sil.size = Vector2(side, side)
	_sil.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


func _silhouette_tex(ship_type: int) -> Texture2D:
	if _sil_cache.has(ship_type):
		return _sil_cache[ship_type]
	var tex: Texture2D = null
	var info: PackedInt32Array = nova.sprite_info(0, ship_type) if ship_type >= 128 else PackedInt32Array()
	if info.size() >= 7 and info[5] > 0 and info[6] > 0:
		var bytes: PackedByteArray = nova.sprite_rgba(0, ship_type)
		if bytes.size() >= info[5] * info[6] * 4:
			var at := AtlasTexture.new()
			at.atlas = ImageTexture.create_from_image(Image.create_from_data(info[5], info[6], false, Image.FORMAT_RGBA8, bytes))
			at.region = Rect2(0, 0, info[0], info[1])   # frame 0: the ship pointing up
			tex = at
	_sil_cache[ship_type] = tex
	return tex


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
	var fs_l := _fs(sub)
	var y := a.position.y + 6.0 * _scale + _asc(sub)
	var pad := 6.0 * _scale
	# One row per commodity aboard (0x004612c0): name dim left, tons bright right.
	for row in _cargo.get("rows", []):
		draw_string(_font, Vector2(roundf(a.position.x + pad), roundf(y)), str(row["name"]), HORIZONTAL_ALIGNMENT_LEFT, a.size.x * 0.6, fs_l, dim)
		var tons := str(int(row["tons"]))
		var tw := _font.get_string_size(tons, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_l).x
		draw_string(_font, Vector2(roundf(a.end.x - pad - tw), roundf(y)), tons, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_l, bright)
		y += _line_h(sub)
	_free_row(a, y, sub, st, dim, bright)
	y += _line_h(st)
	if str(_cargo.get("special", "")) != "":
		draw_string(_font, Vector2(roundf(a.position.x + pad), roundf(y)), "Special:", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_l, dim)
		var lw := _font.get_string_size("Special: ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_l).x
		draw_string(_font, Vector2(roundf(a.position.x + pad + lw), roundf(y)), str(_cargo["special"]),
			HORIZONTAL_ALIGNMENT_LEFT, a.size.x - lw - 2.0 * pad, fs_l, bright)
	# Credits at the foot of the area.
	var cy := a.end.y - 6.0 * _scale - _font.get_descent(_fs(st))
	_text_c("Credits:", a, cy - _line_h(st), sub, dim)
	_text_c(credits_hud(int(nova.player_credits())), a, cy, st, bright)


func _free_row(a: Rect2, y: float, sub: int, st: int, dim: Color, bright: Color) -> void:
	var fs_l := _fs(sub)
	var fs_v := _fs(st)
	var free_s := str(maxi(0, int(_cargo.get("free", nova.cargo_free_tons()))))
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

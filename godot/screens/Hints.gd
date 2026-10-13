# NOVA Swift — one-time tutorial hints.
#
# Port of the Apple app's GameHints.swift (HintBanner / .gameHint) and the "Getting started" card
# of GameContainerView.flightHintsOverlay. The catalog and the "should it show" rule are shared
# Swift (NovaSwiftStory `NovaHints`, behind the bridge's `game_hints()` / `game_hint_for_screen()`);
# this is the presentation, the per-install "seen" flags (Prefs [hints], Apple's UserDefaults) and
# the contexts:
#   - flight: the first time you fly, a "Getting started" card with the core controls
#   - docked: the first landing (hub) "Welcome to the spaceport", the first Mission BBS, the first
#     Outfitter -- an amber banner along the top, dismissible, never shown again
# All of it is gated by Settings > Interface > Tutorial hints, hides under menus / the pause menu,
# and never shows in the training flight. A banner is dismissed by its X (mouse) or after
# AUTO_DISMISS seconds (so a pad / keyboard player never has to click); either way it is recorded
# as seen. "Show all hints again" in Settings clears the flags.
#
# Mouse-only buttons on purpose: the keys and pad buttons belong to the ship and the docked screens.
# Loaded with preload() (no class_name), like the other screens.
extends CanvasLayer

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

## A hint stays this long (unpaused) before it counts as read.
const AUTO_DISMISS := 20.0
const AMBER := Color(1.0, 0.7, 0.28)

var current_id := ""            # the banner / card on screen ("flight" for the Getting started card)
var _nova: Object
var _shell: Object
var _catalog := {}              # hint id -> {id, title, message, key}
var _dismissed := {}            # ids dismissed during this docked visit
var _was_landed := false
var _panel: PanelContainer
var _age := 0.0
## Test seam: a Callable returning the docked Spaceport screen name ("hub", "bbs", ...). Default reads
## Main's Spaceport (a sibling of the shell).
var screen_provider := Callable()


func setup(nova: Object, shell: Object) -> void:
	_nova = nova
	_shell = shell
	layer = 55
	var parsed = JSON.parse_string(nova.game_hints())
	if parsed is Array:
		for h in parsed:
			_catalog[str(h["id"])] = h


## Whether any hint context could apply right now (a pilot is flying / docked, no menu is up).
func _playing() -> bool:
	if _shell == null or _shell.in_menu() or _shell.is_paused() or _shell.is_loading():
		return false
	if _nova.tutorial_active() or not _nova.has_pilot_save():
		return false
	return Prefs.hints_enabled()


func _spaceport_screen() -> String:
	if screen_provider.is_valid():
		return str(screen_provider.call())
	var host: Node = _shell.get_parent() if _shell != null else null
	var sp = host.get("_spaceport") if host != null else null
	if sp != null and sp.is_open():
		return str(sp.get("_screen"))
	return ""


func _process(delta: float) -> void:
	if not _playing():
		_clear()
		return
	var landed: bool = _nova.is_landed()
	if landed != _was_landed:
		_was_landed = landed
		_dismissed.clear()
		_clear()
	var want := ""
	if landed:
		var raw: String = _nova.game_hint_for_screen(_spaceport_screen())
		var h = JSON.parse_string(raw) if raw != "" else null
		if h is Dictionary:
			want = str(h["id"])
			_catalog[want] = h
	elif not bool(Prefs.get_value("hints", "flight_card")):
		want = "flight"
	# NovaHints.shouldShow: active and not dismissed this visit and not seen before.
	if want != "" and (_dismissed.has(want) or (want != "flight" and Prefs.hint_seen(str(_catalog[want]["key"])))):
		want = ""
	if want != current_id:
		_clear()
		if want != "":
			_show(want)
	if current_id != "":
		_age += delta
		if _age >= AUTO_DISMISS:
			dismiss()


func _clear() -> void:
	if _panel != null:
		_panel.queue_free()
		_panel = null
	current_id = ""
	_age = 0.0


## Mark the hint on screen as read and hide it (X, "Got it", or the timeout).
func dismiss() -> void:
	if current_id == "":
		return
	if current_id == "flight":
		Prefs.set_value("hints", "flight_card", true)
		Prefs.save()
	else:
		Prefs.mark_hint_seen(str(_catalog[current_id]["key"]))
	_dismissed[current_id] = true
	_clear()


func _show(id: String) -> void:
	current_id = id
	_age = 0.0
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.82)
	sb.border_color = Color(AMBER.r, AMBER.g, AMBER.b, 0.4)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = Vector2(460, 0)
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.position = Vector2(-230, 14 if id != "flight" else 70)
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = "Getting started" if id == "flight" else str(_catalog[id]["title"])
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", AMBER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var btn := Button.new()
	btn.text = "Got it" if id == "flight" else "✕"
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(dismiss)
	head.add_child(btn)
	var lines: Array = flight_tips() if id == "flight" else [str(_catalog[id]["message"])]
	for t in lines:
		var l := Label.new()
		l.text = ("› " if id == "flight" else "") + str(t)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(430, 0)
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		v.add_child(l)


## The first-flight card's tips (Apple's desktop wording, with this build's bound keys; the pad's
## own buttons when one is connected).
static func flight_tips() -> Array:
	if Controls.pad_connected():
		return ["Left stick to steer and thrust · %s to fire" % Controls.describe_buttons("fire_primary"),
			"%s to target the nearest ship · %s to cycle weapons" % [
				Controls.describe_buttons("target_nearest"), Controls.describe_buttons("secondary_next")],
			"%s to land · %s for the galaxy map" % [
				Controls.describe_buttons("land"), Controls.describe_buttons("galaxy_map")]]
	return ["Steer with %s / %s, thrust with %s · %s to fire" % [
			Controls.describe_keys("turn_left"), Controls.describe_keys("turn_right"),
			Controls.describe_keys("thrust"), Controls.describe_keys("fire_primary")],
		"Click a ship to target it · click a planet to set a course",
		"Press %s to land · %s for the galaxy map · %s to cycle targets" % [
			Controls.describe_keys("land"), Controls.describe_keys("galaxy_map"),
			Controls.describe_keys("target_next")]]

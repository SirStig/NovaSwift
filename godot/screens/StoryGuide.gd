# NOVA Swift — Story Guide / Story Map (Godot).
#
# Port of the Apple Story Guide (app/NovaSwift/Story/StoryGuideView.swift,
# StorylineFlowView.swift, StorylineTagBadge.swift): one window that reconstructs every
# campaign from the mission control-bit graph and shows the pilot where they stand and what
# unlocks the next step. Apple draws it in its own dark style in every presentation mode (it
# is an aftermarket tool EV Nova never had), so this does the same -- no Classic kit frame.
#
#   header   book icon + title, storyline search, Close
#   left     storyline list: tag colour stripe, title, capsule progress, "n/N steps", status
#            badge (Active / Available / Complete / Locked), grouped under a header per
#            contributing plug-in (Base Game first) with source chips once more than one
#            plug-in contributes, "+N one-off jobs" footer
#   right    hero (progress ring, source + faction badges, "Next up" callout with a jump
#            button) over the campaign drawn as a vertical timeline: SVG status nodes on a
#            progress-coloured spine; genuine branches sit in indented lanes with an elbow
#            under a labelled connector ("On refuse", "On failure", "Unlocks", "50/50 chance");
#            each step is a card (state badge, YOU ARE HERE, a detail view with objective,
#            reward, where to get it, government, HOW TO UNLOCK blockers, synopsis, Abort
#            mission for an abortable active mission). Chips hang off a card: "Can end here",
#            "-> Step" jumps to a step already placed (merge/loop), "Leads into / From <other
#            storyline>" cross-campaign switches. Mission-text wildcards such as <RST> render
#            as small token chips ("return planet") instead of raw angle brackets.
#
# Every rule is shared Swift: NovaSwiftStory's StorylineAnalyzer.storyMap(for:) and
# StoryGuideLogic / buildStoryFlow (the very code Apple's StoryGuideModel calls), through
# NovaWorld's "Story Map" section; the map is built on a background queue, so opening is
# instant and shows "Charting your story..." until it lands.
#
# Input (gamepad first, mouse and keyboard equal):
#   stick / d-pad / arrows   move between steps and the storyline list (Godot focus, snapping)
#   A / Enter / click        open or close a step's detail; pick a storyline
#   B / Esc                  back (close)
#   LB / RB, - / +           zoom out / in (text and card scale)
#   right stick / wheel      scroll the flow
#   X / PageUp, Y / PageDown previous / next storyline
#
# Opened with open(parent, nova, storyline_key); the storyline badge on a mission
# row (BBS, offers, Mission Info) uses make_badge(). Loaded with preload()
# (no class_name), like the other screens.
extends CanvasLayer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const SVG = preload("res://ui/novaswift/NovaSVG.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const Prefs = preload("res://Prefs.gd")

signal closed

const COL_PANEL := Color(0.075, 0.075, 0.085)
const COL_SIDE := Color(0.062, 0.062, 0.07)
const COL_CARD := Color(0.105, 0.105, 0.118)
const COL_TEXT := Color(0.93, 0.93, 0.95)
const COL_DIM := Color(0.62, 0.64, 0.7)
const COL_ACCENT := Color(0.98, 0.75, 0.35)      # warm amber, matches the app icon
const COL_RING := Color(1.0, 0.9, 0.55)
const COL_PURPLE := Color(0.72, 0.55, 0.98)
const COL_DONE := Color(0.3, 0.85, 0.4)
const COL_ACTIVE := Color(0.25, 0.85, 0.95)
const COL_AVAIL := Color(0.98, 0.85, 0.25)
const COL_LOCK := Color(0.55, 0.57, 0.62)
const COL_FAIL := Color(1.0, 0.4, 0.35)
const INDENT := 26.0
const ZOOM_MIN := 0.8
const ZOOM_MAX := 1.6
const ZOOM_STEP := 0.1
const PAD_SCROLL := 900.0

## Mission-text wildcards -> a readable name (MissionTextResolver's tag list).
const TOKENS := {
	"DST": "destination", "DSY": "destination system", "RST": "return planet",
	"RSY": "return system", "CT": "cargo", "CQ": "cargo amount", "SN": "ship name",
	"DL": "deadline", "PN": "your name", "PNN": "your nickname", "PSN": "your ship",
	"PST": "your ship type", "OSN": "other ship", "PRK": "your rank", "SRK": "your rank",
	"RRK": "recent rank", "PAY": "payment", "REG": "region",
}

var nova
var layer_index := 70
var selected_key := ""
var plugin_filter := ""          # "" = all sources

static var dpr := 1.0            # physical pixels per logical pixel, for crisp SVG icons

var _root: Control
var _lanes: Array = []
var _untagged := 0
var _body: Control
var _loading_label: Control
var _lane_box: VBoxContainer
var _lane_scroll: ScrollContainer
var _lane_items := {}            # key -> FocusBox
var _overview: VBoxContainer
var _scroll: ScrollContainer
var _flow: VBoxContainer
var _rows: Array = []            # the selected storyline's flow rows (dictionaries)
var _cards := {}                 # step id -> Card
var _card_order: Array = []      # Cards, top to bottom
var _expanded := -1
var _zoom := 1.0
var _wait_for_map := true
var _initial_key := ""
var _focus_after_build := true
var _footer: Control
var _query := ""
var _side_w := 300.0


# ---------------------------------------------------------------- static entry points

## Open the guide over `parent`, optionally focused on a storyline. Returns the screen.
static func open(parent: Node, world, storyline_key := "") -> Node:
	var g := new()
	parent.add_child(g)
	g.setup(world, storyline_key)
	return g


## `{key, title}` for a mission that continues a storyline, `{}` otherwise (untagged, the
## "Show mission storyline tags" setting off, or the tag table still prewarming -- the first
## call starts that; ask again later or just call it every time the row is built).
static func badge_for_mission(world, mission_id: int) -> Dictionary:
	if world == null or not bool(Prefs.get_value("story", "show_mission_storyline_tags")):
		return {}
	var text: String = world.story_tag(mission_id)
	if text == "":
		return {}
	var d = JSON.parse_string(text)
	return d if d is Dictionary else {}


## The small amber book badge for a mission row, wired to open the guide on that lane
## (`host` = any node in the tree to put the guide under). null when the mission has none.
static func make_badge(world, mission_id: int, host: Node) -> Control:
	var tag := badge_for_mission(world, mission_id)
	if tag.is_empty():
		return null
	var b := BadgeButton.new()
	var title := str(tag.get("title", ""))
	b.tooltip_text = "Continues the %s storyline -- open in Story Guide" % title
	b.pressed.connect(func():
		if is_instance_valid(host) and host.is_inside_tree():
			open(host.get_tree().root, world, str(tag.get("key", ""))))
	return b


static func status_color(status: String) -> Color:
	match status:
		"completed": return COL_DONE
		"active": return COL_ACTIVE
		"available": return COL_AVAIL
	return COL_LOCK


static func status_label(status: String) -> String:
	match status:
		"completed": return "Completed"
		"active": return "In progress"
		"available": return "Available now"
	return "Locked"


static func status_icon(status: String) -> String:
	match status:
		"completed": return "checkmark.circle.fill"
		"active": return "target"
		"available": return "sparkles"
	return "lock.fill"


## Storyline-level state for the sidebar badge: complete / active / available / locked.
static func lane_status(l: Dictionary) -> String:
	if bool(l.get("complete", false)):
		return "complete"
	var cs := str(l.get("currentStatus", ""))
	if cs == "active" or int(l.get("done", 0)) > 0:
		return "active"
	if cs == "available":
		return "available"
	return "locked"


static func lane_status_color(s: String) -> Color:
	match s:
		"complete": return COL_DONE
		"active": return COL_ACTIVE
		"available": return COL_AVAIL
	return COL_LOCK


static func lane_status_text(s: String) -> String:
	match s:
		"complete": return "Complete"
		"active": return "Active"
		"available": return "Available"
	return "Locked"


## Plug-in display names by id, filled from the lanes read-out (bridge `pluginLabels`).
static var plugin_names := {}


static func plugin_label(id: String) -> String:
	return "Base Game" if id == "" else str(plugin_names.get(id, id))


static func connector_color(label: String) -> Color:
	match label:
		"On success", "On accept", "On completion": return COL_ACCENT
		"On refuse": return Color(1.0, 0.6, 0.15)
		"On failure", "On abort": return Color(1.0, 0.35, 0.3)
		"50/50 chance": return COL_PURPLE
	return Color(0.62, 0.62, 0.68)


static func connector_icon(label: String) -> String:
	match label:
		"On failure", "On abort": return "xmark.octagon.fill"
		"On refuse": return "arrow.triangle.branch"
		"50/50 chance": return "sparkles"
		"Unlocks": return "lock.open.fill"
	return "arrow.triangle.branch"


## An icon texture crisp at the display's pixel density.
static func tex(icon_name: String, px: int, color: Color) -> Texture2D:
	return SVG.texture(icon_name, int(round(px * dpr)), color)


## A mission-text string as BBCode: `[` escaped, `<RST>`-style wildcards as small token chips.
static func tokens_bbcode(text: String) -> String:
	var out := text.replace("[", "[lb]")
	var re := RegEx.new()
	re.compile("<([A-Za-z]{2,4})([0-9]{0,4})>")
	var found: Array[RegExMatch] = re.search_all(out)
	var i := found.size() - 1
	while i >= 0:
		var m: RegExMatch = found[i]
		var tag := m.get_string(1).to_upper()
		var nice: String = str(TOKENS.get(tag, tag.to_lower()))
		var chip := "[bgcolor=%s][color=%s] %s [/color][/bgcolor]" % [
			Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.2).to_html(true), COL_ACCENT.to_html(false), nice]
		out = out.substr(0, m.get_start()) + chip + out.substr(m.get_end())
		i -= 1
	return out


## Plain-text version for tooltips / sorting: wildcards as "(return planet)".
static func tokens_plain(text: String) -> String:
	var re := RegEx.new()
	re.compile("<([A-Za-z]{2,4})([0-9]{0,4})>")
	var out := text
	var found: Array[RegExMatch] = re.search_all(text)
	var i := found.size() - 1
	while i >= 0:
		var m: RegExMatch = found[i]
		var tag := m.get_string(1).to_upper()
		out = out.substr(0, m.get_start()) + "(" + str(TOKENS.get(tag, tag.to_lower())) + ")" + out.substr(m.get_end())
		i -= 1
	return out


# ---------------------------------------------------------------- inner controls

## A focusable thing that draws itself and emits `activated` on A / Enter / click.
class FocusBox extends Control:
	signal activated
	var draw_fn: Callable
	var selected := false

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _enter_tree() -> void:
		ClassicTheme.track(self)
		ClassicTheme.on_nav_changed(func(_on): queue_redraw())

	func _ready() -> void:
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)

	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept") \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
			accept_event()
			activated.emit()

	func _draw() -> void:
		if draw_fn.is_valid():
			draw_fn.call(self)
		if has_focus():
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0, 0, 0, 0)
			sb.border_color = Color(1.0, 0.9, 0.55)
			sb.set_border_width_all(2)
			sb.set_corner_radius_all(10)
			sb.anti_aliasing = true
			draw_style_box(sb, Rect2(Vector2.ZERO, size))


## The timeline gutter beside a card: lane lines, the progress-coloured spine, the branch
## elbow and the SVG status node (pulsing halo on the current step).
class Rail extends Control:
	var tint := Color.WHITE
	var first := false
	var last := false
	var current := false
	var locked := false
	var status := "locked"
	var depth := 0
	var prev_depth := 0
	var next_depth := 0
	var prev_done := false
	var is_done := false
	var final_step := false
	var ending := false
	var elbow := Color(0, 0, 0, 0)
	const LANE := 24.0
	const NODE_Y := 24.0
	static var dpr := 1.0

	static func tex(icon_name: String, px: int, color: Color) -> Texture2D:
		return SVG.texture(icon_name, int(round(px * dpr)), color)

	static func icon_for(st: String) -> String:
		match st:
			"completed": return "checkmark.circle.fill"
			"active": return "target"
			"available": return "sparkles"
		return "lock.fill"

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func configure(d: int) -> void:
		depth = d
		custom_minimum_size = Vector2(44.0 + d * LANE, 0)
		set_process(current)

	func _ready() -> void:
		set_process(current)

	func _process(_dt: float) -> void:
		queue_redraw()

	func _x(level: int) -> float:
		return 22.0 + level * LANE

	func _draw() -> void:
		var faint := Color(1, 1, 1, 0.13)
		var good := Color(COL_DONE.r, COL_DONE.g, COL_DONE.b, 0.55)
		for l in depth:
			draw_line(Vector2(_x(l), 0), Vector2(_x(l), size.y), faint, 2.0, true)
		var cx := _x(depth)
		var c := Vector2(cx, NODE_Y)
		if not first and prev_depth >= depth:
			draw_line(Vector2(cx, 0), Vector2(cx, NODE_Y), good if prev_done else faint, 2.0, true)
		if not last and next_depth >= depth:
			draw_line(Vector2(cx, NODE_Y), Vector2(cx, size.y), good if is_done else faint, 2.0, true)
		if depth > 0 and (first or prev_depth < depth):
			draw_line(Vector2(_x(depth - 1), NODE_Y), Vector2(cx, NODE_Y), elbow, 2.0, true)
		var r := 13.0 if current else 11.0
		draw_circle(c, r + 4.0, COL_PANEL)
		if current:
			var t := float(Time.get_ticks_msec()) / 1000.0
			var pulse := 0.5 + 0.5 * sin(t * 3.2)
			draw_circle(c, r + 5.0 + pulse * 3.0, Color(tint.r, tint.g, tint.b, 0.10 + 0.14 * (1.0 - pulse)))
			draw_arc(c, r + 3.0, 0.0, TAU, 40, Color(tint.r, tint.g, tint.b, 0.9), 2.0, true)
		var icon_name: String = icon_for(status)
		var col := tint
		var s := r * 2.0
		if locked:
			draw_circle(c, r, Color(0.14, 0.14, 0.16))
			draw_arc(c, r, 0.0, TAU, 32, Color(tint.r, tint.g, tint.b, 0.4), 1.5, true)
			icon_name = "flag.checkered" if final_step else "lock.fill"
			s = r * 1.15
			col = Color(tint.r, tint.g, tint.b, 0.8)
		draw_texture_rect(tex(icon_name, int(s), col), Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false)
		if ending and status != "completed":
			var o := c + Vector2(r * 0.8, r * 0.8)
			draw_circle(o, 7.5, COL_PANEL)
			draw_texture_rect(tex("xmark.octagon.fill", 12, COL_FAIL),
				Rect2(o - Vector2(6, 6), Vector2(12, 12)), false)


## One step of the flow: a focusable panel; A / click toggles its detail.
class Card extends PanelContainer:
	signal activated
	var tint := Color.WHITE
	var locked := false
	var current := false
	var expanded := false

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _ready() -> void:
		focus_entered.connect(restyle)
		focus_exited.connect(restyle)
		restyle()

	func restyle() -> void:
		var bg := COL_CARD
		if not locked:
			bg = COL_CARD.lerp(tint, 0.16 if expanded else (0.11 if current else 0.06))
		var s := StyleBoxFlat.new()
		s.bg_color = bg
		s.set_corner_radius_all(12)
		s.set_content_margin_all(14)
		s.anti_aliasing = true
		if has_focus():
			s.border_color = Color(1.0, 0.9, 0.55)
			s.set_border_width_all(3)
		else:
			var a := 0.85 if expanded else (0.65 if current else (0.18 if locked else 0.3))
			s.border_color = Color(tint.r, tint.g, tint.b, a)
			s.set_border_width_all(2 if (expanded or current) else 1)
		add_theme_stylebox_override("panel", s)

	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept") \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
			accept_event()
			activated.emit()


## A circular progress ring with the percentage (or a check) in the middle.
class Ring extends Control:
	var frac := 0.0
	var col := Color.WHITE
	var complete := false
	var thickness := 6.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - thickness * 0.5 - 1.0
		draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.1), thickness, true)
		if frac > 0.0:
			draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * clampf(frac, 0.0, 1.0), 64, col, thickness, true)
		if complete:
			var s := r * 1.1
			draw_texture_rect(Rail.tex("checkmark", int(s), col), Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false)
		else:
			var f := T.font("body", "bold")
			var txt := "%d%%" % int(round(frac * 100.0))
			var fs := int(r * 0.62)
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(f, Vector2(c.x - w * 0.5, c.y + fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)


## The amber "continues a storyline" book icon (StorylineTagBadge).
class BadgeButton extends Button:
	func _init() -> void:
		flat = true
		focus_mode = Control.FOCUS_ALL
		custom_minimum_size = Vector2(24, 24)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _enter_tree() -> void:
		ClassicTheme.track(self)
		ClassicTheme.on_nav_changed(func(_on): queue_redraw())

	func _ready() -> void:
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _draw() -> void:
		var amber := Color(0.98, 0.75, 0.35)
		var mx := 5.0 if size.x >= 22.0 else 2.0
		var my := 3.0 if size.y >= 22.0 else 1.0
		var r := Rect2(Vector2(mx, my), size - Vector2(mx * 2.0, my * 2.0))
		var fill := 0.5 if ClassicTheme.show_focus(self) else 0.25   # keyboard / pad focus: a brighter fill, no outline
		draw_rect(r, Color(amber.r, amber.g, amber.b, fill), true)
		draw_rect(r, amber, false, 1.5)
		var mid := r.position.x + r.size.x * 0.5
		draw_line(Vector2(mid, r.position.y), Vector2(mid, r.end.y), amber, 1.5)
		for i in 2:
			var y := r.position.y + 5.0 + i * 4.0
			draw_line(Vector2(r.position.x + 2, y), Vector2(mid - 2, y), amber, 1.0)
			draw_line(Vector2(mid + 2, y), Vector2(r.end.x - 2, y), amber, 1.0)


# ---------------------------------------------------------------- small builders

func _icon(parent: Node, icon_name: String, px: int, color: Color) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex(icon_name, px, color)
	tr.custom_minimum_size = Vector2(px, px)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(tr)
	return tr


func _fs(n: int) -> int:
	return int(round(n * _zoom))


## A scaled text label.
func _label(text: String, size: int, color: Color, parent: Node, weight := "regular") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", T.font("body", weight))
	l.add_theme_font_size_override("font_size", _fs(size))
	l.add_theme_color_override("font_color", color)
	var inline: bool = parent is HBoxContainer or parent is HFlowContainer
	l.autowrap_mode = TextServer.AUTOWRAP_OFF if inline else TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(l)
	return l


## Wrapped rich text with wildcard chips.
func _rich(text: String, size: int, color: Color, parent: Node, weight := "regular") -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.selection_enabled = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.focus_mode = Control.FOCUS_NONE
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var f: Font = T.font("body", weight)
	r.add_theme_font_override("normal_font", f)
	r.add_theme_font_override("bold_font", T.font("body", "bold"))
	r.add_theme_font_size_override("normal_font_size", _fs(size))
	r.add_theme_font_size_override("bold_font_size", _fs(size))
	r.add_theme_color_override("default_color", color)
	r.text = tokens_bbcode(text)
	if parent != null:
		parent.add_child(r)
	return r


## A static capsule: optional icon + text, tinted.
func _pill(parent: Node, text: String, color: Color, icon_name := "", size := 11) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(color.r, color.g, color.b, 0.16), 20, Color(color.r, color.g, color.b, 0.0), 0, Vector2(8, 3)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	if icon_name != "":
		_icon(h, icon_name, _fs(size + 1), color)
	if text != "":
		var l := _label(text, size, color, h, "semibold")
		l.autowrap_mode = TextServer.AUTOWRAP_OFF
	if parent != null:
		parent.add_child(p)
	return p


## A tappable capsule (jump / cross-storyline chip).
func _pill_button(text: String, color: Color, icon_name: String, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.clip_text = false
	b.add_theme_stylebox_override("normal", T.box(Color(color.r, color.g, color.b, 0.14), 20, Color(color.r, color.g, color.b, 0.4), 1))
	b.add_theme_stylebox_override("hover", T.box(Color(color.r, color.g, color.b, 0.26), 20, Color(color.r, color.g, color.b, 0.7), 1))
	b.add_theme_stylebox_override("pressed", T.box(Color(color.r, color.g, color.b, 0.36), 20, color, 1))
	b.add_theme_stylebox_override("focus", T.box(Color(color.r, color.g, color.b, 0.26), 20, Color(1.0, 0.9, 0.55), 2))
	b.add_theme_stylebox_override("disabled", T.box(Color(color.r, color.g, color.b, 0.08), 20))
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", 10)
	m.add_theme_constant_override("margin_right", 11)
	m.add_theme_constant_override("margin_top", 4)
	m.add_theme_constant_override("margin_bottom", 4)
	b.add_child(m)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 5)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(h)
	if icon_name != "":
		_icon(h, icon_name, _fs(13), color)
	var l := _label(text, 12, color, h, "semibold")
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	var fit := func():
		if is_instance_valid(b) and is_instance_valid(m):
			b.custom_minimum_size = m.get_combined_minimum_size()
	m.minimum_size_changed.connect(fit)
	fit.call_deferred()
	if cb.is_valid():
		b.pressed.connect(cb)
	else:
		b.disabled = true
	return b


## A key / pad button cap.
func _keycap(parent: Node, text: String) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.1), 5, Color(1, 1, 1, 0.12), 1, Vector2(6, 2)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = text
	T.style_text(l, "body", "bold", T.AMBER, 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	parent.add_child(p)


func _hint(parent: Node, keys: String, what: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	_keycap(h, keys)
	var l := Label.new()
	l.text = what
	T.style_text(l, "body", "regular", COL_DIM, 12)
	h.add_child(l)
	parent.add_child(h)


# ---------------------------------------------------------------- setup

func setup(world, storyline_key := "") -> void:
	nova = world
	layer = layer_index
	_initial_key = storyline_key
	ClassicTheme.setup(world)
	var win := get_window()
	var vp := get_viewport().get_visible_rect().size
	if win != null and vp.x > 0.0:
		dpr = clampf(ceilf(float(win.size.x) / vp.x), 1.0, 3.0)
		Rail.dpr = dpr
	_side_w = 300.0 if vp.x >= 1100.0 else 252.0
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.theme()
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mx: int = clampi(int(vp.x * 0.03), 20, 72)
	margin.add_theme_constant_override("margin_left", mx)
	margin.add_theme_constant_override("margin_right", mx)
	margin.add_theme_constant_override("margin_top", 46)      # clear of the fps badge / pause chrome
	margin.add_theme_constant_override("margin_bottom", 26)
	_root.add_child(margin)
	var panel := PanelContainer.new()
	panel.clip_contents = true
	panel.add_theme_stylebox_override("panel", T.box(COL_PANEL, 16, Color(1, 1, 1, 0.14), 1))
	margin.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)

	# header
	var head_bg := PanelContainer.new()
	head_bg.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.035), 0, Color(0, 0, 0, 0), 0, Vector2(18, 12)))
	col.add_child(head_bg)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	head_bg.add_child(header)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", T.box(Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.18), 10, Color(0, 0, 0, 0), 0, Vector2(7, 7)))
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon(badge, "book.fill", 22, COL_ACCENT)
	header.add_child(badge)
	var tcol := VBoxContainer.new()
	tcol.add_theme_constant_override("separation", 0)
	tcol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(tcol)
	var title := Label.new()
	title.text = "Story Guide"
	T.style_text(title, "heading", "bold", COL_TEXT, 22)
	tcol.add_child(title)
	var lh := HBoxContainer.new()
	lh.add_theme_constant_override("separation", 5)
	_loading_label = lh
	_icon(lh, "clock", 12, COL_DIM)
	var ll := Label.new()
	ll.text = "Charting your story..."
	T.style_text(ll, "body", "regular", COL_DIM, 12)
	lh.add_child(ll)
	tcol.add_child(lh)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)
	var q := NC.search_field(header, "Search storylines", "", _on_query)
	var qp: Control = q.get_meta("panel")
	qp.size_flags_horizontal = Control.SIZE_SHRINK_END
	qp.custom_minimum_size = Vector2(minf(280.0, vp.x * 0.22), 0)
	var close := NC.button("Close", "bordered", close_guide, "xmark")
	close.name = "CloseButton"
	close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(close)
	col.add_child(_hline())

	_body = HBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_body)
	_build_loading()

	col.add_child(_hline())
	var fm := MarginContainer.new()
	fm.add_theme_constant_override("margin_left", 18)
	fm.add_theme_constant_override("margin_right", 18)
	fm.add_theme_constant_override("margin_top", 7)
	fm.add_theme_constant_override("margin_bottom", 7)
	col.add_child(fm)
	var fh := HFlowContainer.new()
	fh.add_theme_constant_override("h_separation", 18)
	fh.add_theme_constant_override("v_separation", 4)
	fm.add_child(fh)
	_footer = fh
	var pad := not Input.get_connected_joypads().is_empty()
	_hint(fh, "A" if pad else "Enter", "open / close")
	_hint(fh, "B" if pad else "Esc", "back")
	_hint(fh, "LB / RB" if pad else "- / +", "zoom")
	_hint(fh, "R-Stick" if pad else "Wheel", "scroll")
	_hint(fh, "X / Y" if pad else "PgUp / PgDn", "storyline")

	nova.story_map_begin()


func _hline() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.1)
	r.custom_minimum_size = Vector2(0, 1)
	return r


func _vline() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.1)
	r.custom_minimum_size = Vector2(1, 0)
	return r


func _build_loading() -> void:
	var c := CenterContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(c)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	c.add_child(v)
	var ic := _icon(v, "map", 52, Color(1, 1, 1, 0.25))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var t := Label.new()
	t.text = "Charting your story..."
	T.style_text(t, "body", "medium", COL_DIM, 16)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)


func _process(delta: float) -> void:
	if _wait_for_map:
		if nova != null and nova.story_map_ready():
			_wait_for_map = false
			_loading_label.visible = false
			_map_loaded()
		return
	# Right stick scrolls the flow (Godot focus already follows the left stick / d-pad).
	if _scroll != null and is_instance_valid(_scroll):
		var ry := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if absf(ry) > 0.25:
			_scroll.scroll_vertical += int(ry * PAD_SCROLL * delta)


func close_guide() -> void:
	closed.emit()
	queue_free()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close_guide()
	elif _typing():
		return
	elif (InputMap.has_action("map_zoom_in") and event.is_action_pressed("map_zoom_in")) \
			or (event is InputEventKey and event.pressed and event.keycode == KEY_EQUAL):
		get_viewport().set_input_as_handled()
		set_zoom(_zoom + ZOOM_STEP)
	elif (InputMap.has_action("map_zoom_out") and event.is_action_pressed("map_zoom_out")) \
			or (event is InputEventKey and event.pressed and event.keycode == KEY_MINUS):
		get_viewport().set_input_as_handled()
		set_zoom(_zoom - ZOOM_STEP)
	elif (event is InputEventKey and event.pressed and event.keycode == KEY_PAGEDOWN) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y):
		get_viewport().set_input_as_handled()
		cycle_lane(1)
	elif (event is InputEventKey and event.pressed and event.keycode == KEY_PAGEUP) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_X):
		get_viewport().set_input_as_handled()
		cycle_lane(-1)


## True while a text field has focus (so "-" / "=" type instead of zooming).
func _typing() -> bool:
	var f: Control = get_viewport().gui_get_focus_owner()
	return f is LineEdit


# ---------------------------------------------------------------- data

func _json(text: String):
	return JSON.parse_string(text)


func _map_loaded() -> void:
	var d = _json(nova.story_map_lanes())
	_lanes = d.get("lanes", []) if d is Dictionary else []
	_untagged = int(d.get("untagged", 0)) if d is Dictionary else 0
	plugin_names = d.get("pluginLabels", {}) if d is Dictionary else {}
	for c in _body.get_children():
		c.queue_free()
	if _lanes.is_empty():
		_build_empty()
		return
	_build_sidebar()
	_build_right()
	var key := selected_key if selected_key != "" else _initial_key
	var keys: Array = _lanes.map(func(l): return l.key)
	if key == "" or not keys.has(key):
		key = keys[0]
	select_lane(key, true)


## Re-pull the map after the pilot changed (mission completed / bit set): rebuild in the
## background and redraw the current lane when it lands.
func refresh() -> void:
	nova.story_map_begin()
	_wait_for_map = true
	_loading_label.visible = true
	_initial_key = selected_key
	_focus_after_build = false


func lane_keys() -> Array:
	return _lanes.map(func(l): return l.key)


func lane(key: String) -> Dictionary:
	for l in _lanes:
		if l.key == key:
			return l
	return {}


func set_zoom(z: float) -> void:
	var nz := clampf(snappedf(z, 0.05), ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(nz, _zoom):
		return
	_zoom = nz
	if selected_key != "":
		_build_flow(true)


func zoom() -> float:
	return _zoom


# ---------------------------------------------------------------- states

func _build_empty() -> void:
	var c := CenterContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(c)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	c.add_child(v)
	var ic := _icon(v, "book", 56, Color(1, 1, 1, 0.3))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var t := Label.new()
	t.text = "No storylines found"
	T.style_text(t, "heading", "bold", COL_TEXT, 22)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := Label.new()
	s.text = "Load your EV Nova data (or a plug-in with campaigns) to chart the story."
	T.style_text(s, "body", "regular", COL_DIM, 14)
	v.add_child(s)
	var b := NC.button("Close", "primary", close_guide)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(b)
	b.grab_focus.call_deferred()


# ---------------------------------------------------------------- sidebar

func _plugin_ids() -> Array:
	var ids := {}
	for l in _lanes:
		ids[str(l.plugin)] = true
	var out: Array = ids.keys()
	out.sort_custom(func(a, b):
		if (a == "") != (b == ""):
			return a == ""            # Base Game always first
		return plugin_label(a) < plugin_label(b))
	return out


func _build_sidebar() -> void:
	var bg := PanelContainer.new()
	bg.custom_minimum_size = Vector2(_side_w, 0)
	bg.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bg.add_theme_stylebox_override("panel", T.box(COL_SIDE, 0))
	_body.add_child(bg)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 0)
	bg.add_child(inner)
	if _plugin_ids().size() > 1:
		var fm := MarginContainer.new()
		fm.name = "SourceFilter"
		for s in ["left", "right", "top"]:
			fm.add_theme_constant_override("margin_" + s, 10)
		fm.add_theme_constant_override("margin_bottom", 2)
		inner.add_child(fm)
		var fl := HFlowContainer.new()
		fl.add_theme_constant_override("h_separation", 6)
		fl.add_theme_constant_override("v_separation", 6)
		fm.add_child(fl)
		_fill_filter(fl)
	_lane_scroll = ScrollContainer.new()
	_lane_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lane_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_lane_scroll.follow_focus = true
	inner.add_child(_lane_scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side_name in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side_name, 10)
	_lane_scroll.add_child(m)
	_lane_box = VBoxContainer.new()
	_lane_box.add_theme_constant_override("separation", 5)
	_lane_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(_lane_box)
	_fill_lanes()
	_body.add_child(_vline())


func _fill_filter(fl: Control) -> void:
	for c in fl.get_children():
		fl.remove_child(c)
		c.queue_free()
	var opts: Array = [""]
	opts.append_array(_plugin_ids())
	for id in opts:
		var pid: String = str(id)
		var label := "All" if pid == "" else plugin_label(pid)
		var b := NC.chip(fl, label, plugin_filter == pid, _set_filter.bind(pid))
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_stylebox_override("normal", T.box(Color(1, 1, 1, 0.08), 40, Color(0, 0, 0, 0), 0, Vector2(10, 4)))
		b.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.14), 40, Color(0, 0, 0, 0), 0, Vector2(10, 4)))
		b.add_theme_stylebox_override("pressed", T.box(T.ACCENT.darkened(0.2), 40, Color(0, 0, 0, 0), 0, Vector2(10, 4)))
		b.add_theme_stylebox_override("hover_pressed", T.box(T.ACCENT.darkened(0.2), 40, Color(0, 0, 0, 0), 0, Vector2(10, 4)))


func _set_filter(pid: String) -> void:
	plugin_filter = pid
	var fm = _body.find_child("SourceFilter", true, false)
	if fm != null:
		_fill_filter(fm.get_child(0))
	_fill_lanes()


func _cycle_filter() -> void:
	var ids := _plugin_ids()
	var next := ""
	if plugin_filter == "" or not ids.has(plugin_filter):
		next = ids[0]
	else:
		var i := ids.find(plugin_filter) + 1
		next = ids[i] if i < ids.size() else ""
	_set_filter(next)


func _on_query(text: String) -> void:
	_query = text.strip_edges().to_lower()
	if _lane_box != null:
		_fill_lanes()


func _fill_lanes() -> void:
	for c in _lane_box.get_children():
		_lane_box.remove_child(c)
		c.queue_free()
	_lane_items.clear()
	var shown := 0
	for pid in _plugin_ids():
		if plugin_filter != "" and pid != plugin_filter:
			continue
		var group: Array = _lanes.filter(func(l):
			return str(l.plugin) == pid and (_query == "" or str(l.title).to_lower().contains(_query)))
		if group.is_empty():
			continue
		var hh := HBoxContainer.new()
		hh.add_theme_constant_override("separation", 6)
		var hm := MarginContainer.new()
		hm.add_theme_constant_override("margin_top", 8 if shown > 0 else 2)
		hm.add_theme_constant_override("margin_left", 4)
		hm.add_child(hh)
		_icon(hh, "square.stack.3d.up" if pid != "" else "star.fill", 12, COL_DIM)
		var h := Label.new()
		h.text = plugin_label(pid).to_upper()
		T.style_text(h, "body", "bold", COL_DIM, 11)
		hh.add_child(h)
		var cnt := Label.new()
		cnt.text = str(group.size())
		T.style_text(cnt, "body", "regular", Color(1, 1, 1, 0.3), 11)
		hh.add_child(cnt)
		_lane_box.add_child(hm)
		for l in group:
			var item := FocusBox.new()
			item.custom_minimum_size = Vector2(0, 78)
			item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			item.set_meta("lane", l)
			item.draw_fn = _draw_lane
			item.activated.connect(select_lane.bind(str(l.key), false))
			_lane_box.add_child(item)
			_lane_items[str(l.key)] = item
			shown += 1
	if shown == 0:
		var e := Label.new()
		e.text = "No storylines match."
		T.style_text(e, "body", "regular", COL_DIM, 13)
		_lane_box.add_child(e)
	if _untagged > 0 and plugin_filter == "" and _query == "":
		var u := Label.new()
		u.text = "+ %d one-off jobs" % _untagged
		T.style_text(u, "body", "regular", COL_DIM, 12)
		var um := MarginContainer.new()
		um.add_theme_constant_override("margin_left", 4)
		um.add_theme_constant_override("margin_top", 6)
		um.add_child(u)
		_lane_box.add_child(um)
	_refresh_lane_selection()


func _refresh_lane_selection() -> void:
	for k in _lane_items:
		_lane_items[k].selected = (k == selected_key)
		_lane_items[k].queue_redraw()


func _draw_lane(box: Control) -> void:
	var l: Dictionary = box.get_meta("lane")
	var sel: bool = box.selected
	var w: float = box.size.x
	var hovered: bool = box.get_global_rect().has_point(box.get_global_mouse_position())
	var bg_col := Color(1, 1, 1, 0.045)
	if sel:
		bg_col = Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.15)
	elif hovered:
		bg_col = Color(1, 1, 1, 0.08)
	var edge := Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.55) if sel else Color(1, 1, 1, 0.06)
	box.draw_style_box(T.box(bg_col, 10, edge, 1), Rect2(Vector2.ZERO, box.size))
	var col: Array = l.get("color", [0.62, 0.62, 0.62])
	var tag := Color(float(col[0]), float(col[1]), float(col[2]))
	box.draw_style_box(T.box(tag, 2), Rect2(7, 12, 4, box.size.y - 24))
	var st := lane_status(l)
	var done: int = int(l.done)
	var total: int = int(l.total)
	var f: Font = T.font("body", "semibold")
	var title_w := w - 28.0 - (22.0 if st == "complete" else 0.0)
	box.draw_string(f, Vector2(20, 27), str(l.title), HORIZONTAL_ALIGNMENT_LEFT, title_w, 14, COL_TEXT)
	if st == "complete":
		box.draw_texture_rect(tex("checkmark.seal.fill", 16, COL_DONE), Rect2(w - 28, 12, 16, 16), false)
	var frac := 0.0 if total == 0 else float(done) / float(total)
	var bar := Rect2(20, 38, w - 34, 5)
	box.draw_style_box(T.box(Color(1, 1, 1, 0.12), 3), bar)
	if frac > 0.0:
		box.draw_style_box(T.box(COL_DONE if st == "complete" else tag.lerp(COL_ACCENT, 0.35), 3),
			Rect2(bar.position, Vector2(maxf(5.0, bar.size.x * frac), bar.size.y)))
	box.draw_string(T.font("body", "regular"), Vector2(20, 64), "%d/%d steps" % [done, total],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_DIM)
	var txt := lane_status_text(st)
	var sc := lane_status_color(st)
	var pf: Font = T.font("body", "semibold")
	var tw := pf.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var pill := Rect2(w - tw - 36, 50, tw + 24, 20)
	box.draw_style_box(T.box(Color(sc.r, sc.g, sc.b, 0.16), 10), pill)
	box.draw_texture_rect(tex(status_icon("completed" if st == "complete" else ("active" if st == "active" else ("available" if st == "available" else "locked"))), 11, sc),
		Rect2(pill.position + Vector2(6, 4.5), Vector2(11, 11)), false)
	box.draw_string(pf, pill.position + Vector2(20, 14), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sc)


func cycle_lane(dir: int) -> void:
	var keys := lane_keys()
	if keys.is_empty():
		return
	var i := keys.find(selected_key)
	select_lane(keys[posmod(i + dir, keys.size())], false)


# ---------------------------------------------------------------- right pane

func _build_right() -> void:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 0)
	_body.add_child(right)
	var om := MarginContainer.new()
	for s in ["left", "right"]:
		om.add_theme_constant_override("margin_" + s, 18)
	om.add_theme_constant_override("margin_top", 14)
	om.add_theme_constant_override("margin_bottom", 10)
	right.add_child(om)
	_overview = VBoxContainer.new()
	_overview.add_theme_constant_override("separation", 10)
	om.add_child(_overview)
	# legend
	var lm := MarginContainer.new()
	lm.add_theme_constant_override("margin_left", 18)
	lm.add_theme_constant_override("margin_right", 18)
	lm.add_theme_constant_override("margin_bottom", 8)
	right.add_child(lm)
	var lg := HFlowContainer.new()
	lg.add_theme_constant_override("h_separation", 16)
	lg.add_theme_constant_override("v_separation", 2)
	lm.add_child(lg)
	for e in [["checkmark.circle.fill", "Done", COL_DONE], ["target", "You are here", COL_ACTIVE],
			["sparkles", "Available", COL_AVAIL], ["lock.fill", "Locked", COL_LOCK],
			["xmark.octagon.fill", "Possible ending", COL_FAIL]]:
		var lh := HBoxContainer.new()
		lh.add_theme_constant_override("separation", 5)
		_icon(lh, str(e[0]), 12, e[2])
		var ll := Label.new()
		ll.text = str(e[1])
		T.style_text(ll, "body", "regular", COL_DIM, 11)
		lh.add_child(ll)
		lg.add_child(lh)
	right.add_child(_hline())
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	right.add_child(_scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_left", 14)
	m.add_theme_constant_override("margin_right", 20)
	m.add_theme_constant_override("margin_top", 16)
	m.add_theme_constant_override("margin_bottom", 24)
	_scroll.add_child(m)
	_flow = VBoxContainer.new()
	_flow.add_theme_constant_override("separation", 0)
	_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(_flow)


func select_lane(key: String, focus_current: bool = false) -> void:
	if lane(key).is_empty():
		return
	selected_key = key
	_expanded = -1
	_refresh_lane_selection()
	_build_flow(false)
	_build_overview()
	if focus_current or _focus_after_build:
		_focus_current_card()
	_focus_after_build = true


func _lane_color(l: Dictionary) -> Color:
	var col: Array = l.get("color", [0.62, 0.62, 0.62])
	return Color(float(col[0]), float(col[1]), float(col[2]))


func _current_row_id() -> int:
	for row in _rows:
		if bool(row.current):
			return int(row.id)
	return -1


func _build_overview() -> void:
	for c in _overview.get_children():
		_overview.remove_child(c)
		c.queue_free()
	var l := lane(selected_key)
	var tag := _lane_color(l)
	var st := lane_status(l)
	var done: int = int(l.done)
	var total: int = int(l.total)
	var hero := PanelContainer.new()
	var hs := T.box(Color(tag.r, tag.g, tag.b, 0.10), 14, Color(tag.r, tag.g, tag.b, 0.35), 1, Vector2(16, 14))
	hero.add_theme_stylebox_override("panel", hs)
	_overview.add_child(hero)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 10)
	hero.add_child(hv)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	hv.add_child(top)
	var ring := Ring.new()
	ring.custom_minimum_size = Vector2(64, 64)
	ring.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ring.frac = 0.0 if total == 0 else float(done) / float(total)
	ring.col = COL_DONE if st == "complete" else tag.lerp(COL_ACCENT, 0.4)
	ring.complete = st == "complete"
	top.add_child(ring)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 6)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(info)
	var t := Label.new()
	t.text = str(l.title)
	T.style_text(t, "heading", "bold", COL_TEXT, 22)
	t.clip_text = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(t)
	var badges := HFlowContainer.new()
	badges.add_theme_constant_override("h_separation", 6)
	badges.add_theme_constant_override("v_separation", 4)
	info.add_child(badges)
	_pill(badges, plugin_label(str(l.plugin)), COL_DIM, "square.stack.3d.up" if str(l.plugin) != "" else "star.fill", 11)
	if str(l.govtName) != "":
		_pill(badges, str(l.govtName), tag.lerp(Color.WHITE, 0.45), "person.2.fill", 11)
	_pill(badges, lane_status_text(st), lane_status_color(st),
		"checkmark.seal.fill" if st == "complete" else ("target" if st == "active" else ("sparkles" if st == "available" else "lock.fill")), 11)
	var cnt := Label.new()
	cnt.text = "%d / %d steps" % [done, total]
	T.style_text(cnt, "body", "semibold", COL_DIM, 13)
	cnt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(cnt)
	# capsule progress
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	bar.max_value = maxf(1.0, float(total))
	bar.value = float(done)
	bar.add_theme_stylebox_override("fill", T.box(COL_DONE if st == "complete" else tag.lerp(COL_ACCENT, 0.35), 4))
	bar.add_theme_stylebox_override("background", T.box(Color(1, 1, 1, 0.12), 4))
	hv.add_child(bar)
	# next-up callout
	if str(l.currentName) != "":
		var avail := str(l.currentStatus) == "available"
		var cc := COL_AVAIL if avail else COL_ACTIVE
		var call := PanelContainer.new()
		call.add_theme_stylebox_override("panel", T.box(Color(cc.r, cc.g, cc.b, 0.12), 10, Color(cc.r, cc.g, cc.b, 0.4), 1, Vector2(12, 9)))
		hv.add_child(call)
		var ch := HBoxContainer.new()
		ch.add_theme_constant_override("separation", 10)
		call.add_child(ch)
		_icon(ch, "location.fill", 18, cc)
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 1)
		cv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ch.add_child(cv)
		_label("AVAILABLE NOW" if avail else "NEXT UP", 10, cc, cv, "bold")
		_rich(str(l.currentName), 14, COL_TEXT, cv, "semibold")
		var rid := _current_row_id()
		if rid >= 0:
			var go := NC.button("Show step", "bordered", jump_to.bind(rid), "arrow.right")
			go.name = "ShowStep"
			go.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			ch.add_child(go)


func _build_flow(keep_scroll: bool) -> void:
	var prev := _scroll.scroll_vertical if keep_scroll else 0
	for c in _flow.get_children():
		_flow.remove_child(c)
		c.queue_free()
	_cards.clear()
	_card_order.clear()
	var d = _json(nova.story_flow(selected_key))
	_rows = d if d is Array else []
	for i in _rows.size():
		_flow.add_child(_make_row(i))
	if keep_scroll:
		(func(): if is_instance_valid(_scroll): _scroll.scroll_vertical = prev).call_deferred()
	else:
		_scroll.scroll_vertical = 0


func _make_row(i: int) -> Control:
	var row: Dictionary = _rows[i]
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	var depth := int(row.depth)
	var status := str(row.status)
	var rail := Rail.new()
	rail.current = bool(row.current)
	rail.first = i == 0
	rail.last = i == _rows.size() - 1
	rail.prev_depth = int(_rows[i - 1].depth) if i > 0 else 0
	rail.next_depth = int(_rows[i + 1].depth) if i < _rows.size() - 1 else 0
	rail.prev_done = i > 0 and str(_rows[i - 1].status) == "completed"
	rail.is_done = status == "completed"
	rail.locked = status == "locked"
	rail.status = status
	rail.final_step = rail.last and depth == 0
	rail.ending = str(row.deadEnds) != ""
	rail.tint = status_color(status)
	rail.elbow = connector_color(str(row.connector)) if str(row.connector) != "" else Color(1, 1, 1, 0.2)
	rail.configure(depth)
	h.add_child(rail)
	var card := Card.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	card.tint = status_color(status)
	card.locked = rail.locked
	card.current = bool(row.current)
	card.set_meta("row", i)
	card.activated.connect(toggle_row.bind(int(row.id)))
	var cm := MarginContainer.new()
	cm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cm.add_theme_constant_override("margin_bottom", int(12 * _zoom))
	cm.add_child(card)
	h.add_child(cm)
	_cards[int(row.id)] = card
	_card_order.append(card)
	_fill_card(card, row)
	return h


func _summary(row: Dictionary) -> String:
	match str(row.status):
		"locked":
			var bl: Array = row.blockers
			if bl.is_empty():
				return "Prerequisites not yet met."
			for b in bl:
				if not bool(b.unknown) and str(b.hint) != "":
					return "Unlocks after: " + str(b.hint)
			return "Select to see what is needed."
		"available": return "Available now - %s" % row.offeredAt
	return str(row.objective)


func _fill_card(card: Card, row: Dictionary) -> void:
	for c in card.get_children():
		card.remove_child(c)
		c.queue_free()
	var id := int(row.id)
	var expanded := id == _expanded
	card.expanded = expanded
	card.restyle()
	var status := str(row.status)
	var tint := status_color(status)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", int(7 * _zoom))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var conn := str(row.connector)
	var top := HFlowContainer.new()
	top.add_theme_constant_override("h_separation", 7)
	top.add_theme_constant_override("v_separation", 4)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(top)
	if conn != "":
		_pill(top, conn.to_upper(), connector_color(conn), connector_icon(conn), 10)
	var stp := _label("Step %d" % int(row.step), 12, COL_DIM, top, "semibold")
	stp.autowrap_mode = TextServer.AUTOWRAP_OFF
	stp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if bool(row.current):
		_pill(top, "YOU ARE HERE", COL_ACCENT, "location.fill", 10)
	if status == "locked":
		var lk := _icon(top, "lock.fill", _fs(12), Color(COL_LOCK.r, COL_LOCK.g, COL_LOCK.b, 0.8))
		lk.tooltip_text = "Locked"
	else:
		_pill(top, status_label(status), tint, status_icon(status), 10)
	_rich(str(row.name), 16, Color(0.8, 0.88, 0.8) if status == "completed" else (COL_DIM if status == "locked" else COL_TEXT), v, "semibold")
	var sm := _rich(_summary(row), 13, COL_DIM, v)
	if not expanded:
		sm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sm.custom_minimum_size.y = 0
	if expanded:
		_fill_detail(v, row)
	_fill_chips(v, row)
	_ignore_mouse_except_buttons(v)


## One "icon  LABEL  value" row in the detail view.
func _field(icon_name: String, label: String, value: String, parent: Node) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(h)
	var ic := _icon(h, icon_name, _fs(14), COL_ACCENT)
	ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)
	_label(label.to_upper(), 10, COL_DIM, col, "bold")
	_rich(value, 13, COL_TEXT, col)


func _fill_detail(v: VBoxContainer, row: Dictionary) -> void:
	var status := str(row.status)
	var sep := _hline()
	v.add_child(sep)
	if status != "locked":
		_field("target", "Objective", str(row.objective), v)
	_field("gift.fill", "Reward", str(row.reward), v)
	if status == "available":
		_field("mappin.circle.fill", "Get it at", str(row.offeredAt), v)
	if str(row.govtName) != "":
		_field("person.2.fill", "Government", str(row.govtName), v)
	if status == "locked":
		var uh := HBoxContainer.new()
		uh.add_theme_constant_override("separation", 6)
		uh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(uh)
		_icon(uh, "lock.open.fill", _fs(13), COL_ACCENT)
		_label("HOW TO UNLOCK", 11, COL_ACCENT, uh, "bold")
		var blockers: Array = row.blockers
		if blockers.is_empty():
			_label("Prerequisites not yet met.", 13, COL_DIM, v)
		for b in blockers:
			var bh := HBoxContainer.new()
			bh.add_theme_constant_override("separation", 8)
			bh.mouse_filter = Control.MOUSE_FILTER_IGNORE
			v.add_child(bh)
			var known: bool = not bool(b.unknown) and str(b.hint) != ""
			var ic := _icon(bh, "chevron.right", _fs(11), COL_ACCENT if known else COL_DIM)
			ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			if known:
				_rich(str(b.hint), 13, COL_TEXT, bh)
			else:
				_rich("Needs bit %d %s -- source unknown (may be a plug-in)." \
					% [int(b.bit), "set" if bool(b.needsSet) else "cleared"], 13, COL_DIM, bh)
	if str(row.synopsis) != "":
		var q := PanelContainer.new()
		q.mouse_filter = Control.MOUSE_FILTER_IGNORE
		q.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.05), 8, Color(0, 0, 0, 0), 0, Vector2(10, 8)))
		v.add_child(q)
		_rich(str(row.synopsis), 13, COL_DIM, q)
	if bool(row.canAbort):
		var ab := NC.button("Abort mission", "destructive", _abort.bind(int(row.id)), "xmark.octagon.fill")
		ab.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		v.add_child(ab)


func _fill_chips(v: VBoxContainer, row: Dictionary) -> void:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 5)
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var any := false
	if str(row.deadEnds) != "":
		_pill(flow, "Can end here - " + str(row.deadEnds), COL_FAIL, "xmark.octagon.fill", 11)
		any = true
	for j in row.jumps:
		var lbl := str(j.label)
		var tint := connector_color(lbl)
		var ico := "arrow.triangle.merge" if lbl == "" or lbl == "Leads to" else connector_icon(lbl)
		flow.add_child(_pill_button("%s -> %s" % [lbl if lbl != "" else "Leads to", tokens_plain(str(j.name))],
			tint, ico, jump_to.bind(int(j.id))))
		any = true
	for x in row.cross:
		var text := ("Leads into " if bool(x.outgoing) else "From ") + str(x.key)
		flow.add_child(_pill_button(text, COL_ACCENT, "book.fill" if bool(x.outgoing) else "arrow.triangle.branch",
			select_lane.bind(str(x.key), true)))
		any = true
	if any:
		v.add_child(flow)
	else:
		flow.queue_free()


func _ignore_mouse_except_buttons(n: Node) -> void:
	for c in n.get_children():
		if c is Control and not (c is BaseButton):
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_except_buttons(c)


# ---------------------------------------------------------------- behaviour

## Open / close a step's detail (one at a time, like StorylineFlowView).
func toggle_row(id: int) -> void:
	var old := _expanded
	_expanded = -1 if old == id else id
	for rid in [old, _expanded]:
		if rid >= 0 and _cards.has(rid):
			var card: Card = _cards[rid]
			_fill_card(card, _rows[int(card.get_meta("row"))])
	if _expanded >= 0 and _cards.has(_expanded):
		_cards[_expanded].grab_focus.call_deferred()


## Follow a "-> Step" chip: expand the target and bring it to the middle.
func jump_to(id: int) -> void:
	if not _cards.has(id):
		return
	if _expanded != id:
		toggle_row(id)
	_scroll_to_center(_cards[id])
	_cards[id].grab_focus.call_deferred()


func _scroll_to_center(c: Control) -> void:
	await get_tree().process_frame
	if not is_instance_valid(c) or not is_instance_valid(_scroll):
		return
	var y := c.global_position.y - _scroll.global_position.y + _scroll.scroll_vertical
	_scroll.scroll_vertical = int(y - (_scroll.size.y - c.size.y) * 0.5)


func _focus_current_card() -> void:
	var target: Control = null
	for row in _rows:
		if bool(row.current) and _cards.has(int(row.id)):
			target = _cards[int(row.id)]
	if target == null and not _card_order.is_empty():
		target = _card_order[0]
	if target == null:
		var item = _lane_items.get(selected_key)
		if item != null:
			item.grab_focus.call_deferred()
		return
	target.grab_focus.call_deferred()
	_scroll_to_center(target)


func _abort(id: int) -> void:
	if nova.mission_abort(id):
		refresh()


# ---------------------------------------------------------------- test seams

func card_count() -> int:
	return _card_order.size()


func row_at(i: int) -> Dictionary:
	return _rows[i] if i >= 0 and i < _rows.size() else {}


func card_at(i: int) -> Control:
	return _card_order[i] if i >= 0 and i < _card_order.size() else null


func expanded_id() -> int:
	return _expanded


func lane_item(key: String) -> Control:
	return _lane_items.get(key)

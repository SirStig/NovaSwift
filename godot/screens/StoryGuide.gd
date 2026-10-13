# NOVA Swift — Story Guide / Story Map (Godot).
#
# Port of the Apple Story Guide (app/NovaSwift/Story/StoryGuideView.swift,
# StorylineFlowView.swift, StorylineTagBadge.swift): one window that reconstructs every
# campaign from the mission control-bit graph and shows the pilot where they stand and what
# unlocks the next step. Apple draws it in its own dark style in every presentation mode (it
# is an aftermarket tool EV Nova never had), so this does the same -- no Classic kit frame.
#
#   left   storyline list: government-colour swatch, title, progress bar, "n/N steps", grouped
#          under a header per contributing plug-in (Base Game first) with a source filter
#          once more than one plug-in contributes, "+N one-off jobs" footer
#   right  overview bar (title, plug-in, n / N or Complete, progress, "Next: ..." objective)
#          over the campaign drawn as a vertical flow: a plain chain is a straight column,
#          genuine branches indent one level under a labelled connector ("On refuse",
#          "On failure", "Unlocks", "50/50 chance", ...); each step is a card with status
#          (Completed / In progress / Available now / Locked), YOU ARE HERE on the first
#          not-completed step, and a detail view (objective, reward, where to get it,
#          government, HOW TO UNLOCK blockers with their NCB bit sources, synopsis, Abort
#          mission for an abortable active mission). Chips hang off a card: "Can end here",
#          "-> Step" jumps to a step already placed (merge/loop), "Leads into / From <other
#          storyline>" cross-campaign switches.
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
# Opened with StoryGuide.open(parent, nova, storyline_key); the storyline badge on a mission
# row (BBS, offers, Mission Info) uses StoryGuide.make_badge(). Loaded with preload()
# (no class_name), like the other screens.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const Prefs = preload("res://Prefs.gd")

signal closed

const COL_PANEL := Color(0.09, 0.09, 0.09)
const COL_TEXT := Color(0.92, 0.92, 0.92)
const COL_DIM := Color(0.62, 0.64, 0.7)
const COL_ACCENT := Color(0.98, 0.75, 0.35)      # warm amber, matches the app icon
const COL_RING := Color(1.0, 0.9, 0.55)
const COL_PURPLE := Color(0.72, 0.55, 0.98)
const INDENT := 26.0
const LANE_W := 260.0
const ZOOM_MIN := 0.8
const ZOOM_MAX := 1.6
const ZOOM_STEP := 0.1
const PAD_SCROLL := 900.0

var nova
var layer_index := 70
var selected_key := ""
var plugin_filter := ""          # "" = all sources

var _root: Control
var _lanes: Array = []
var _untagged := 0
var _body: Control
var _loading_label: Label
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
var _footer: Label


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
		"completed": return Color(0.3, 0.85, 0.4)
		"active": return Color(0.25, 0.85, 0.95)
		"available": return Color(0.98, 0.85, 0.25)
	return Color(0.55, 0.57, 0.62)


static func status_label(status: String) -> String:
	match status:
		"completed": return "Completed"
		"active": return "In progress"
		"available": return "Available now"
	return "Locked"


static func plugin_label(id: String) -> String:
	return "Base Game" if id == "" else id


static func connector_color(label: String) -> Color:
	match label:
		"On success", "On accept", "On completion": return COL_ACCENT
		"On refuse": return Color(1.0, 0.6, 0.15)
		"On failure", "On abort": return Color(1.0, 0.35, 0.3)
		"50/50 chance": return COL_PURPLE
	return Color(0.62, 0.62, 0.62)


# ---------------------------------------------------------------- inner controls

## A focusable thing that draws itself and emits `activated` on A / Enter / click.
class FocusBox extends Control:
	signal activated
	var draw_fn: Callable
	var selected := false

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP

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
			draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.9, 0.55), false, 3.0)


## The timeline spine and status node beside a card.
class Rail extends Control:
	var tint := Color.WHITE
	var first := false
	var last := false
	var current := false
	var locked := false

	func _init() -> void:
		custom_minimum_size = Vector2(26, 0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var cx := 13.0
		var line := Color(1, 1, 1, 0.14)
		if not first:
			draw_line(Vector2(cx, 0), Vector2(cx, 14), line, 2.0)
		if not last:
			draw_line(Vector2(cx, 14), Vector2(cx, size.y), line, 2.0)
		var r := 8.0 if current else 6.0
		var c := Vector2(cx, 14.0)
		draw_circle(c, r, Color(0.09, 0.09, 0.09))
		draw_circle(c, r, Color(tint.r, tint.g, tint.b, 0.5 if locked else 0.9))
		draw_arc(c, r, 0, TAU, 24, tint, 2.5 if current else 1.5, true)


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

	func _ready() -> void:
		focus_entered.connect(restyle)
		focus_exited.connect(restyle)
		restyle()

	func restyle() -> void:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.11, 0.11, 0.11) if locked \
			else Color(0.09, 0.09, 0.09).lerp(tint, 0.16 if expanded else 0.10)
		s.set_corner_radius_all(9)
		s.set_content_margin_all(12)
		if has_focus():
			s.border_color = Color(1.0, 0.9, 0.55)
			s.set_border_width_all(3)
		else:
			var a := 0.85 if expanded else (0.6 if current else 0.28)
			s.border_color = Color(tint.r, tint.g, tint.b, a)
			s.set_border_width_all(2 if (expanded or current) else 1)
		add_theme_stylebox_override("panel", s)

	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept") \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
			accept_event()
			activated.emit()


## The amber "continues a storyline" book icon (StorylineTagBadge).
class BadgeButton extends Button:
	func _init() -> void:
		flat = true
		focus_mode = Control.FOCUS_ALL
		custom_minimum_size = Vector2(24, 24)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _ready() -> void:
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _draw() -> void:
		var amber := Color(0.98, 0.75, 0.35)
		var r := Rect2(Vector2(5, 3), size - Vector2(10, 6))
		draw_rect(r, Color(amber.r, amber.g, amber.b, 0.25), true)
		draw_rect(r, amber, false, 1.5)
		var mid := r.position.x + r.size.x * 0.5
		draw_line(Vector2(mid, r.position.y), Vector2(mid, r.end.y), amber, 1.5)
		for i in 2:
			var y := r.position.y + 5.0 + i * 4.0
			draw_line(Vector2(r.position.x + 2, y), Vector2(mid - 2, y), amber, 1.0)
			draw_line(Vector2(mid + 2, y), Vector2(r.end.x - 2, y), amber, 1.0)
		if has_focus():
			draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.9, 0.55), false, 2.0)


# ---------------------------------------------------------------- setup

func setup(world, storyline_key := "") -> void:
	nova = world
	layer = layer_index
	_initial_key = storyline_key
	ClassicTheme.setup(world)
	var th: Theme = ShellUI.theme().duplicate()
	th.default_font = ClassicTheme.body_font()
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = th
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 60)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 36)
	_root.add_child(margin)
	var panel := PanelContainer.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color = COL_PANEL
	ps.border_color = Color(0.45, 0.5, 0.6)
	ps.set_border_width_all(2)
	ps.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", ps)
	margin.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 16)
	hm.add_theme_constant_override("margin_right", 12)
	hm.add_theme_constant_override("margin_top", 10)
	hm.add_theme_constant_override("margin_bottom", 10)
	hm.add_child(header)
	col.add_child(hm)
	var title := Label.new()
	title.text = "Story Guide"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COL_TEXT)
	header.add_child(title)
	_loading_label = Label.new()
	_loading_label.text = "Charting your story..."
	_loading_label.add_theme_color_override("font_color", COL_DIM)
	header.add_child(_loading_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(90, 34)
	close.pressed.connect(close_guide)
	header.add_child(close)
	col.add_child(HSeparator.new())

	_body = HBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_body)

	_footer = Label.new()
	_footer.text = "A open / close  -  B back  -  LB / RB zoom  -  right stick scroll  -  X / Y storyline"
	_footer.add_theme_font_size_override("font_size", 12)
	_footer.add_theme_color_override("font_color", COL_DIM)
	var fm := MarginContainer.new()
	fm.add_theme_constant_override("margin_left", 16)
	fm.add_theme_constant_override("margin_top", 6)
	fm.add_theme_constant_override("margin_bottom", 6)
	fm.add_child(_footer)
	col.add_child(HSeparator.new())
	col.add_child(fm)

	nova.story_map_begin()


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


# ---------------------------------------------------------------- data

func _json(text: String):
	return JSON.parse_string(text)


func _map_loaded() -> void:
	var d = _json(nova.story_map_lanes())
	_lanes = d.get("lanes", []) if d is Dictionary else []
	_untagged = int(d.get("untagged", 0)) if d is Dictionary else 0
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


func _fs(n: int) -> int:
	return int(round(n * _zoom))


# ---------------------------------------------------------------- states

func _build_empty() -> void:
	var c := CenterContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(c)
	var v := VBoxContainer.new()
	c.add_child(v)
	var t := Label.new()
	t.text = "No storylines found"
	t.add_theme_font_size_override("font_size", 22)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := Label.new()
	s.text = "Load your EV Nova data (or a plug-in with campaigns) to chart the story."
	s.add_theme_color_override("font_color", COL_DIM)
	v.add_child(s)
	var b := Button.new()
	b.text = "Close"
	b.pressed.connect(close_guide)
	v.add_child(b)
	ShellUI.focus(b)


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
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(LANE_W, 0)
	side.add_theme_constant_override("separation", 0)
	_body.add_child(side)
	var bg := PanelContainer.new()
	bg.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, 0.03)
	bg.add_theme_stylebox_override("panel", s)
	side.add_child(bg)
	var inner := VBoxContainer.new()
	bg.add_child(inner)
	if _plugin_ids().size() > 1:
		var fb := Button.new()
		fb.name = "SourceFilter"
		fb.custom_minimum_size = Vector2(0, 32)
		fb.pressed.connect(_cycle_filter)
		inner.add_child(fb)
		fb.text = "Source: " + (plugin_label(plugin_filter) if plugin_filter != "" else "All")
	_lane_scroll = ScrollContainer.new()
	_lane_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lane_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_lane_scroll.follow_focus = true
	inner.add_child(_lane_scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side_name in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side_name, 8)
	_lane_scroll.add_child(m)
	_lane_box = VBoxContainer.new()
	_lane_box.add_theme_constant_override("separation", 4)
	_lane_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(_lane_box)
	_fill_lanes()
	_body.add_child(VSeparator.new())


func _cycle_filter() -> void:
	var ids := _plugin_ids()
	if plugin_filter == "" or not ids.has(plugin_filter):
		plugin_filter = ids[0]
	else:
		var i := ids.find(plugin_filter) + 1
		plugin_filter = ids[i] if i < ids.size() else ""
	var fb = _body.find_child("SourceFilter", true, false)
	if fb != null:
		fb.text = "Source: " + (plugin_label(plugin_filter) if plugin_filter != "" else "All")
	_fill_lanes()


func _fill_lanes() -> void:
	for c in _lane_box.get_children():
		_lane_box.remove_child(c)
		c.queue_free()
	_lane_items.clear()
	for pid in _plugin_ids():
		if plugin_filter != "" and pid != plugin_filter:
			continue
		var group: Array = _lanes.filter(func(l): return str(l.plugin) == pid)
		if group.is_empty():
			continue
		var h := Label.new()
		h.text = plugin_label(pid).to_upper()
		h.add_theme_font_size_override("font_size", 12)
		h.add_theme_color_override("font_color", COL_DIM)
		_lane_box.add_child(h)
		for l in group:
			var item := FocusBox.new()
			item.custom_minimum_size = Vector2(0, 62)
			item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			item.set_meta("lane", l)
			item.draw_fn = _draw_lane
			item.activated.connect(select_lane.bind(str(l.key), false))
			_lane_box.add_child(item)
			_lane_items[str(l.key)] = item
	if _untagged > 0 and plugin_filter == "":
		var u := Label.new()
		u.text = "+ %d one-off jobs" % _untagged
		u.add_theme_font_size_override("font_size", 12)
		u.add_theme_color_override("font_color", COL_DIM)
		_lane_box.add_child(u)
	_refresh_lane_selection()


func _refresh_lane_selection() -> void:
	for k in _lane_items:
		_lane_items[k].selected = (k == selected_key)
		_lane_items[k].queue_redraw()


func _draw_lane(box: Control) -> void:
	var l: Dictionary = box.get_meta("lane")
	var font := box.get_theme_default_font()
	var sel: bool = box.selected
	if sel:
		box.draw_rect(Rect2(Vector2.ZERO, box.size), Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.18))
	elif box.get_global_rect().has_point(box.get_global_mouse_position()):
		box.draw_rect(Rect2(Vector2.ZERO, box.size), Color(1, 1, 1, 0.06))
	var col: Array = l.get("color", [0.62, 0.62, 0.62])
	box.draw_rect(Rect2(2, 4, 4, box.size.y - 8), Color(col[0], col[1], col[2]))
	var done: int = int(l.done)
	var total: int = int(l.total)
	box.draw_string(font, Vector2(16, 20), str(l.title), HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 44, 15, COL_TEXT)
	if bool(l.complete):
		box.draw_string(font, Vector2(box.size.x - 24, 20), "OK", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.3, 0.85, 0.4))
	var bar := Rect2(16, 30, box.size.x - 28, 6)
	box.draw_rect(bar, Color(1, 1, 1, 0.12))
	var frac := 0.0 if total == 0 else float(done) / float(total)
	box.draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)),
		Color(0.3, 0.85, 0.4) if bool(l.complete) else COL_ACCENT)
	box.draw_string(font, Vector2(16, 54), "%d/%d steps" % [done, total], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_DIM)


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
	var ob := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, 0.03)
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 10
	s.content_margin_bottom = 8
	ob.add_theme_stylebox_override("panel", s)
	right.add_child(ob)
	_overview = VBoxContainer.new()
	_overview.add_theme_constant_override("separation", 6)
	ob.add_child(_overview)
	right.add_child(HSeparator.new())
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	right.add_child(_scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side_name in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side_name, 14)
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
	_build_overview()
	_build_flow(false)
	if focus_current or _focus_after_build:
		_focus_current_card()
	_focus_after_build = true


func _build_overview() -> void:
	for c in _overview.get_children():
		_overview.remove_child(c)
		c.queue_free()
	var l := lane(selected_key)
	var top := HBoxContainer.new()
	_overview.add_child(top)
	var t := Label.new()
	t.text = str(l.title)
	t.add_theme_font_size_override("font_size", 17)
	t.add_theme_color_override("font_color", COL_TEXT)
	top.add_child(t)
	var p := Label.new()
	p.text = "  " + plugin_label(str(l.plugin)) + ("  -  " + str(l.govtName) if str(l.govtName) != "" else "")
	p.add_theme_color_override("font_color", COL_DIM)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(p)
	var r := Label.new()
	if bool(l.complete):
		r.text = "Complete"
		r.add_theme_color_override("font_color", Color(0.3, 0.85, 0.4))
	else:
		r.text = "%d / %d" % [int(l.done), int(l.total)]
		r.add_theme_color_override("font_color", COL_DIM)
	top.add_child(r)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 6)
	bar.max_value = maxf(1.0, float(l.total))
	bar.value = float(l.done)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.3, 0.85, 0.4) if bool(l.complete) else COL_ACCENT
	var back := StyleBoxFlat.new()
	back.bg_color = Color(1, 1, 1, 0.12)
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", back)
	_overview.add_child(bar)
	if str(l.currentName) != "":
		var verb := "Available" if str(l.currentStatus) == "available" else "Next"
		var o := Label.new()
		o.text = "%s: %s" % [verb, l.currentName]
		o.add_theme_font_size_override("font_size", 13)
		o.add_theme_color_override("font_color", COL_DIM)
		_overview.add_child(o)


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
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_bottom", int(10 * _zoom))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	wrap.add_child(h)
	var depth := int(row.depth)
	if depth > 0:
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(depth * INDENT * _zoom, 0)
		h.add_child(sp)
	var rail := Rail.new()
	rail.first = i == 0
	rail.last = i == _rows.size() - 1
	rail.current = bool(row.current)
	rail.locked = str(row.status) == "locked"
	rail.tint = status_color(str(row.status))
	h.add_child(rail)
	var card := Card.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tint = status_color(str(row.status))
	card.locked = rail.locked
	card.current = bool(row.current)
	card.set_meta("row", i)
	card.activated.connect(toggle_row.bind(int(row.id)))
	h.add_child(card)
	_cards[int(row.id)] = card
	_card_order.append(card)
	_fill_card(card, row)
	return wrap


func _label(text: String, size: int, color: Color, parent: Node) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", _fs(size))
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _field(label: String, value: String, parent: Node) -> void:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.selection_enabled = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", _fs(13))
	r.add_theme_font_size_override("bold_font_size", _fs(13))
	r.add_theme_color_override("default_color", COL_DIM)
	r.text = "[b]%s:[/b] %s" % [label, value.replace("[", "[lb]")]
	parent.add_child(r)


func _summary(row: Dictionary) -> String:
	match str(row.status):
		"locked":
			return "Prerequisites not yet met." if (row.blockers as Array).is_empty() \
				else "Locked -- select to see how to unlock."
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
	v.add_theme_constant_override("separation", int(6 * _zoom))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var conn := str(row.connector)
	if conn != "":
		_label(conn.to_upper(), 11, connector_color(conn), v)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(top)
	var stp := _label("Step %d" % int(row.step), 12, COL_DIM, top)
	stp.autowrap_mode = TextServer.AUTOWRAP_OFF
	if bool(row.current):
		var here := _label("  YOU ARE HERE", 11, COL_ACCENT, top)
		here.autowrap_mode = TextServer.AUTOWRAP_OFF
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(sp)
	var st := _label(status_label(status).to_upper(), 11, tint, top)
	st.autowrap_mode = TextServer.AUTOWRAP_OFF
	var nm := _label(str(row.name), 16, COL_TEXT if status != "completed" else Color(0.75, 0.82, 0.75), v)
	nm.add_theme_font_override("font", ClassicTheme.body_font())
	var sm := _label(_summary(row), 13, COL_DIM, v)
	if not expanded:
		sm.max_lines_visible = 2
	if expanded:
		_fill_detail(v, row)
	_fill_chips(v, row)
	_ignore_mouse_except_buttons(v)


func _fill_detail(v: VBoxContainer, row: Dictionary) -> void:
	var status := str(row.status)
	v.add_child(HSeparator.new())
	if status != "locked":
		_field("Objective", str(row.objective), v)
	_field("Reward", str(row.reward), v)
	if status == "available":
		_field("Get it at", str(row.offeredAt), v)
	if str(row.govtName) != "":
		_field("Government", str(row.govtName), v)
	if status == "locked":
		_label("HOW TO UNLOCK", 11, COL_ACCENT, v)
		var blockers: Array = row.blockers
		if blockers.is_empty():
			_label("Prerequisites not yet met.", 13, COL_DIM, v)
		for b in blockers:
			if not bool(b.unknown) and str(b.hint) != "":
				_label("-> " + str(b.hint), 13, COL_TEXT, v)
			else:
				_label("Needs bit %d %s -- source unknown (may be a plug-in)." \
					% [int(b.bit), "set" if bool(b.needsSet) else "cleared"], 13, COL_DIM, v)
	if str(row.synopsis) != "":
		v.add_child(HSeparator.new())
		_label(str(row.synopsis), 13, COL_DIM, v)
	if bool(row.canAbort):
		var ab := Button.new()
		ab.text = "Abort mission"
		ab.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35))
		ab.add_theme_color_override("font_focus_color", Color(1.0, 0.55, 0.5))
		ab.pressed.connect(_abort.bind(int(row.id)))
		v.add_child(ab)


func _chip(text: String, tint: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", _fs(12))
	b.add_theme_color_override("font_color", tint)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.pressed.connect(cb)
	if not cb.is_valid():
		b.disabled = true
	return b


func _fill_chips(v: VBoxContainer, row: Dictionary) -> void:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 4)
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var any := false
	if str(row.deadEnds) != "":
		var c := Label.new()
		c.text = "Can end here - " + str(row.deadEnds)
		c.add_theme_font_size_override("font_size", _fs(12))
		c.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35))
		flow.add_child(c)
		any = true
	for j in row.jumps:
		var tint := connector_color(str(j.label))
		flow.add_child(_chip("%s -> %s" % [j.label, j.name], tint, jump_to.bind(int(j.id))))
		any = true
	for x in row.cross:
		var text := ("Leads into " if bool(x.outgoing) else "From ") + str(x.key)
		flow.add_child(_chip(text, COL_ACCENT, select_lane.bind(str(x.key), true)))
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
			ShellUI.focus(item)
		return
	ShellUI.focus(target)
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

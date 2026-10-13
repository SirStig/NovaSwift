# NOVA Swift — Classic UI kit: helpers for the spaceport / story / comm screens.
#
# Thin layer over ClassicDialog for dialogs drawn on a frame PICT with items placed
# at their DITL rects (the Apple app's NovaMenu + DITLPlacement): rect lookup from the
# loaded DITL (stock rect as fallback), text/scroll/picture helpers, flat focusable
# list rows, and the 4x5 item grid the outfitter / shipyard / hire-escort share.
#
# Loaded with preload() (no class_name), like the rest of the kit. Additive: it only
# uses ClassicDialog's public builders plus `_register` for custom focusables.
extends RefCounted

const T = preload("res://ui/classic/ClassicTheme.gd")
const CD = preload("res://ui/classic/ClassicDialog.gd")

const BODY := 11
const AMBER := Color(1.0, 0.82, 0.4)
const GOLD := Color(1.0, 0.85, 0.4)
const DIM := Color(0.75, 0.75, 0.75)

static var _cache := {}


static func reset() -> void:
	_cache = {}


## DITL item rects of `id`: {index: Rect2i} (empty when the data has no such DITL).
static func rects(nova: Object, id: int) -> Dictionary:
	var key := "%d:%d" % [nova.get_instance_id(), id]
	if _cache.has(key):
		return _cache[key]
	var out := {}
	var parsed = JSON.parse_string(nova.classic_dialog(id))
	if parsed is Dictionary:
		for it in parsed.get("items", []):
			out[int(it["i"])] = Rect2i(int(it["l"]), int(it["t"]), int(it["r"]) - int(it["l"]), int(it["b"]) - int(it["t"]))
	_cache[key] = out
	return out


## Rect of DITL item `idx`, or `stock` when the data lacks it.
static func rect(nova: Object, id: int, idx: int, stock: Rect2i) -> Rect2i:
	var r: Dictionary = rects(nova, id)
	return r.get(idx, stock)


## A dialog on frame PICT `frame_pict` sized to the PICT, no items built (add them with
## the helpers below). Falls back to a dark plate when the PICT is missing.
static func frame(nova: Object, ditl_id: int, frame_pict: int, opts := {}) -> Control:
	var o := {"frame_pict": frame_pict, "default_item": -1}
	o.merge(opts, true)
	return CD.from_ditl(nova, ditl_id, o)


# --- items ---------------------------------------------------------------------------

static func text(d: Control, s: String, r: Rect2i, size := BODY, color := Color(), align := HORIZONTAL_ALIGNMENT_LEFT,
		bold := false, index := -1) -> Label:
	var l: Label = d.add_label(s, r, index, size, color, bold)
	l.horizontal_alignment = align
	return l


static func button(d: Control, label: String, r: Rect2i, idx: int, cb: Callable, enabled := true, node_name := "") -> TextureButton:
	var b: TextureButton = d.add_button(label, r, idx)
	b.disabled = not enabled
	d.actions[idx] = cb
	b.set_meta("fkey", node_name if node_name != "" else "b%d" % idx)
	if node_name != "":
		b.name = node_name
	return b


static func picture(d: Control, tex: Texture2D, r: Rect2i, mode := TextureRect.STRETCH_SCALE) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = mode
	tr.clip_contents = true
	tr.position = Vector2(r.position)
	tr.size = Vector2(r.size)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.add_child(tr)
	return tr


## Wrapped text in a clipped pane that scrolls (wheel, or the right stick).
class PaneScroll extends ScrollContainer:
	var label: Label

	func _process(_dt: float) -> void:
		if not is_visible_in_tree():
			return
		var ax := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if absf(ax) > 0.35:
			scroll_vertical += int(ax * 8.0)


static func scroll_text(d: Control, s: String, r: Rect2i, size := BODY, color := Color()) -> PaneScroll:
	var sc := PaneScroll.new()
	sc.position = Vector2(r.position)
	sc.size = Vector2(r.size)
	sc.set_deferred("size", Vector2(r.size))   # the pane's own minimum goes stale like a Label's
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.mouse_filter = Control.MOUSE_FILTER_PASS
	sc.get_v_scroll_bar().modulate = Color(1, 1, 1, 0)
	var l := Label.new()
	l.text = s
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(r.size.x - 4, 0)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_override("font", T.body_font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color if color != Color() else d.text_color)
	l.add_theme_constant_override("line_spacing", 0)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	sc.add_child(l)
	sc.label = l
	d.add_child(sc)
	return sc


static func credits(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if n < 0 else "") + out


## The original's abbreviated amount ("850", "12,345", "1.23M" — truncated).
static func credits_abbr(n: int) -> String:
	if n >= 1000000:
		return "%d.%02dM" % [n / 1000000, (n % 1000000) / 10000]
	return credits(n)


# --- flat focusable list row ------------------------------------------------------------

## A BaseButton (NOT a Button: Button's minimum height is the theme font's line, which
## stretched every 13 px list row to ~19 px so the highlight hung below the text).
## The highlight is the cölr listHilite over exactly the row rect; a keyboard/pad-focused
## row shows it too (only while ClassicTheme.nav_active), the mouse leaves it alone.
class Row extends BaseButton:
	var hi: ColorRect
	var selected := false

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		hi = ColorRect.new()
		hi.color = T.color("listHilite")
		hi.set_anchors_preset(Control.PRESET_FULL_RECT)
		hi.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hi.visible = false
		add_child(hi)
		focus_entered.connect(_sync)
		focus_exited.connect(_sync)

	func _enter_tree() -> void:
		T.track(self)
		T.on_nav_changed(func(_on): _sync())

	func set_selected(on: bool) -> void:
		selected = on
		_sync()

	func _sync() -> void:
		hi.visible = selected or T.show_focus(self)


## A flat Button over `r` registered as a focusable item `idx` of dialog `d`.
static func row(d: Control, r: Rect2i, idx: int) -> Row:
	var b := Row.new()
	b.position = Vector2(r.position)
	b.size = Vector2(r.size)
	d.add_child(b)
	d._register(idx, b, r, true)
	return b


static func cell(parent: Control, s: String, x: int, w: int, h: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT, size := BODY - 1) -> Label:
	var l := Label.new()
	l.text = s
	l.position = Vector2(x, 0)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING   # never "…": shrink to fit instead
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", T.body_font())
	l.add_theme_font_size_override("font_size", T.fit_size(T.body_font(), s, w, size))
	l.add_theme_color_override("font_color", color)
	# Size LAST: a Control clamps `size` to its minimum at assignment time, and with the
	# default 16 px theme font that minimum is 23 px — a 13 px row cell became 23 px tall
	# with its text centred 5 px below the row highlight.
	l.size = Vector2(w, h)
	l.set_deferred("size", Vector2(w, h))    # the cached minimum is stale until the next frame
	parent.add_child(l)
	return l


# --- focus bookkeeping ----------------------------------------------------------------------

## Enable / disable keyboard-pad focus for every focusable of `d` (a dialog under a modal).
static func set_enabled(d: Control, on: bool) -> void:
	if d == null or not is_instance_valid(d):
		return
	for f in d._focusables:
		var c: Control = f["ctrl"]
		if not is_instance_valid(c):
			continue
		if on:
			if c.has_meta("_fm"):
				c.focus_mode = c.get_meta("_fm")
				c.remove_meta("_fm")
		elif not c.has_meta("_fm"):
			c.set_meta("_fm", c.focus_mode)
			c.focus_mode = Control.FOCUS_NONE


## fkey of the focus owner when it belongs to dialog `d`, else "".
static func focus_key(d: Control) -> String:
	if d == null or not is_instance_valid(d) or not d.is_inside_tree():
		return ""
	var f := d.get_viewport().gui_get_focus_owner()
	if f != null and d.is_ancestor_of(f) and f.has_meta("fkey"):
		return str(f.get_meta("fkey"))
	return ""


static func focus_by_key(d: Control, key: String) -> bool:
	for f in d._focusables:
		var c: Control = f["ctrl"]
		if c.has_meta("fkey") and str(c.get_meta("fkey")) == key and c.focus_mode != Control.FOCUS_NONE \
				and not (c is BaseButton and c.disabled):
			c.grab_focus.call_deferred()
			return true
	return false


# --- the 4x5 item grid ------------------------------------------------------------------------

const TILE := Vector2i(83, 54)
const COLS := 4
const ROWS := 5

class Tile extends Button:
	var grid
	var slot := 0
	var pic: TextureRect
	var lbl: Label
	var qty: Label
	var box: ReferenceRect
	var has_item := false

	func _init() -> void:
		flat = true
		custom_minimum_size = Vector2(83, 54)
		size = Vector2(83, 54)
		clip_contents = true
		var empty := StyleBoxEmpty.new()
		for n in ["normal", "pressed", "disabled", "hover", "focus"]:
			add_theme_stylebox_override(n, empty)
		var bg := ColorRect.new()
		bg.color = Color.BLACK
		bg.size = Vector2(83, 54)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)
		pic = TextureRect.new()
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.position = Vector2(21, 1)
		pic.size = Vector2(41, 40)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pic)
		lbl = Label.new()
		lbl.position = Vector2(0, 41)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.clip_text = true
		lbl.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		lbl.add_theme_font_override("font", T.body_font())
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_constant_override("line_spacing", 0)
		lbl.size = Vector2(83, 12)    # after the font overrides (see cell())
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(lbl)
		qty = Label.new()
		qty.position = Vector2(40, 0)
		qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty.add_theme_font_override("font", T.body_font())
		qty.add_theme_font_size_override("font_size", 10)
		qty.size = Vector2(41, 12)
		qty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(qty)
		box = ReferenceRect.new()
		box.editor_only = false
		box.border_width = 1.0
		box.size = Vector2(83, 54)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(box)
		focus_entered.connect(func(): if grid != null: grid.tile_focused(slot))
		pressed.connect(func(): if grid != null: grid.tile_pressed(slot))

	func show_item(item, selected: bool) -> void:
		has_item = item != null
		visible = true
		focus_mode = Control.FOCUS_ALL if has_item else Control.FOCUS_NONE
		if not has_item:
			pic.texture = null
			lbl.text = ""
			qty.text = ""
			box.border_color = Color(0, 0, 0, 0)
			modulate = Color.WHITE
			return
		pic.texture = item.get("tex")
		T.fit_label(lbl, str(item.get("name", "")), 81.0, 10)
		var q := int(item.get("qty", 0))
		qty.text = str(q) if q > 0 else ""
		var dim: bool = item.get("locked", false)
		modulate = Color(1, 1, 1, 0.45) if dim else Color.WHITE
		set_selected(selected)

	func set_selected(sel: bool) -> void:
		if has_item:
			box.border_color = T.color("gridBright") if sel else T.color("gridDim")

	func _gui_input(ev: InputEvent) -> void:
		if grid == null:
			return
		if ev is InputEventMouseButton and ev.pressed:
			if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
				grid.scroll(-1)
				accept_event()
			elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				grid.scroll(1)
				accept_event()
			return
		if not has_item:
			return
		var dir := -1
		if ev.is_action_pressed("ui_left"):
			dir = 0
		elif ev.is_action_pressed("ui_right"):
			dir = 1
		elif ev.is_action_pressed("ui_up"):
			dir = 2
		elif ev.is_action_pressed("ui_down"):
			dir = 3
		if dir >= 0 and grid.nav(slot, dir):
			accept_event()

	func _notification(what: int) -> void:
		pass   # no focus outline: the selection box (gridBright) is the indication


## A scrolling 4x5 grid of 83x54 item tiles inside dialog `d` at `r` (DITL grid item).
class ItemGrid extends RefCounted:
	var d: Control
	var tiles: Array = []
	var items: Array = []        # [{id, name, tex, qty, locked}]
	var top_row := 0
	var sel_id := -1
	var on_select := Callable()  # (id)
	var on_activate := Callable()  # (id): a tile was pressed
	var on_scroll := Callable()  # ()

	func build(dialog: Control, r: Rect2i, first_idx: int) -> void:
		d = dialog
		for i in COLS * ROWS:
			var t := Tile.new()
			t.grid = self
			t.slot = i
			t.position = Vector2(r.position.x + (i % COLS) * TILE.x, r.position.y + (i / COLS) * TILE.y)
			t.name = "tile%d" % i
			t.set_meta("fkey", "tile%d" % i)
			d.add_child(t)
			d._register(first_idx + i, t, Rect2i(Vector2i(t.position), TILE), true)
			tiles.append(t)

	func max_top() -> int:
		return maxi(0, (items.size() + COLS - 1) / COLS - ROWS)

	func index_of(id: int) -> int:
		for i in items.size():
			if int(items[i]["id"]) == id:
				return i
		return -1

	func set_items(list: Array, selected: int, top := 0) -> void:
		items = list
		top_row = clampi(top, 0, max_top())
		sel_id = selected
		var si := index_of(sel_id)
		if si >= 0:
			_reveal(si)
		refresh()

	func _reveal(i: int) -> void:
		var row := i / COLS
		if row < top_row:
			top_row = row
		elif row >= top_row + ROWS:
			top_row = row - ROWS + 1
		top_row = clampi(top_row, 0, max_top())

	func refresh() -> void:
		for s in tiles.size():
			var idx := top_row * COLS + s
			var item = items[idx] if idx < items.size() else null
			tiles[s].show_item(item, item != null and int(item["id"]) == sel_id)
		if on_scroll.is_valid():
			on_scroll.call()

	func slot_of_selected() -> int:
		var i := index_of(sel_id)
		return i - top_row * COLS if i >= 0 else -1

	func scroll(dr: int) -> void:
		var nt := clampi(top_row + dr, 0, max_top())
		if nt == top_row:
			return
		top_row = nt
		refresh()

	func select_index(i: int, focus := true) -> void:
		if i < 0 or i >= items.size():
			return
		_reveal(i)
		sel_id = int(items[i]["id"])
		refresh()
		if focus:
			tiles[i - top_row * COLS].grab_focus()
		if on_select.is_valid():
			on_select.call(sel_id)

	func tile_focused(slot: int) -> void:
		var idx := top_row * COLS + slot
		if idx >= items.size():
			return
		var id := int(items[idx]["id"])
		if id != sel_id:
			sel_id = id
			for s in tiles.size():
				tiles[s].set_selected(s == slot)
			if on_select.is_valid():
				on_select.call(id)

	func tile_pressed(slot: int) -> void:
		var idx := top_row * COLS + slot
		if idx >= items.size():
			return
		tile_focused(slot)
		if on_activate.is_valid():
			on_activate.call(int(items[idx]["id"]))

	## Arrow key / d-pad inside the grid. false = leave to the default focus search.
	func nav(slot: int, dir: int) -> bool:
		var cur := top_row * COLS + slot
		var target := cur
		match dir:
			0:
				if slot % COLS == 0:
					return false
				target = cur - 1
			1:
				if slot % COLS == COLS - 1:
					return false
				target = cur + 1
			2:
				target = cur - COLS
			3:
				target = cur + COLS
		if target < 0 or target >= items.size() or target == cur:
			return false
		select_index(target, true)
		return true

# Classic-sprite stand-in for Apple's HD / 3D viewer. Same split: sidebar of sprite owners,
# turntable with frame scrub, spin, zoom and background. NovaSwiftHD is not linked, so there
# is no HD image and no 3D hull — the note says so, and the stage shows the rlëD frame.
extends CanvasLayer

const DevUI = preload("res://debug/DevUI.gd")

signal closed

var _tools: Node
var _entries: Array = []
var _list: ItemList
var _search: LineEdit
var _category: OptionButton
var _note: Label
var _stage: TextureRect
var _well: ColorRect
var _caption: Label
var _info: Label
var _slider: HSlider
var _spin: CheckButton
var _zoom: HSlider
var _bg: OptionButton
var _spawn: OptionButton
var _frame := 0
var _frame_count := 1
var _sprite := -1
var _spin_t := 0.0
var _size := Vector2i.ZERO

const BACKGROUNDS := [Color(0.02, 0.03, 0.05), Color(0.45, 0.47, 0.5), Color(0.92, 0.93, 0.95)]


func setup(tools: Node) -> void:
	_tools = tools
	layer = 120
	_build()
	_load_catalog()


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 36
	panel.offset_top = 28
	panel.offset_right = -36
	panel.offset_bottom = -28
	panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)
	var bar := HBoxContainer.new()
	col.add_child(bar)
	var title := DevUI.label(bar, "HD / 3D Viewer", 16, DevUI.GREEN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	DevUI.button(bar, "Done", _close, DevUI.TEXT)
	_note = DevUI.wrap_label(col, "", 11, DevUI.AMBER)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 300
	col.add_child(split)
	split.add_child(_sidebar())
	split.add_child(_detail())


func _sidebar() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(260, 0)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_search = LineEdit.new()
	_search.placeholder_text = "Search sprites"
	_search.text_changed.connect(func(_t): _fill_list())
	box.add_child(_search)
	_category = OptionButton.new()
	_category.add_item("All categories")
	_category.item_selected.connect(func(_i): _fill_list())
	box.add_child(_category)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_pick)
	box.add_child(_list)
	return box


func _detail() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_well = Control.new()
	_well.custom_minimum_size = Vector2(0, 240)
	_well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_well)
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = BACKGROUNDS[0]
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_well.add_child(backdrop)
	_stage = TextureRect.new()
	_stage.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_stage.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_well.add_child(_stage)
	_caption = DevUI.label(box, "Select a sprite", 12, DevUI.DIM)
	var row := HBoxContainer.new()
	box.add_child(row)
	DevUI.button(row, "◀", func(): _step(-1), DevUI.TEXT)
	DevUI.button(row, "▶", func(): _step(1), DevUI.TEXT)
	_spin = CheckButton.new()
	_spin.text = "Spin"
	_spin.toggled.connect(func(on: bool) -> void:
		_spin_t = 0.0
		set_process(on))
	row.add_child(_spin)
	_slider = HSlider.new()
	_slider.min_value = 0
	_slider.max_value = 1
	_slider.step = 1
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.value_changed.connect(func(v: float) -> void:
		if _spin.button_pressed:
			return
		_show_frame(int(v)))
	row.add_child(_slider)
	var row2 := HBoxContainer.new()
	box.add_child(row2)
	row2.add_child(DevUI.label(row2, "Background", 12, DevUI.DIM))
	_bg = OptionButton.new()
	_bg.add_item("Space")
	_bg.add_item("Grey")
	_bg.add_item("White")
	_bg.item_selected.connect(func(i: int) -> void:
		var bg_rect := _well.get_node_or_null("Backdrop")
		if bg_rect is ColorRect:
			bg_rect.color = BACKGROUNDS[i])
	row2.add_child(_bg)
	row2.add_child(DevUI.label(row2, "Zoom", 12, DevUI.DIM))
	_zoom = HSlider.new()
	_zoom.min_value = 1
	_zoom.max_value = 8
	_zoom.step = 0.1
	_zoom.value = 1
	_zoom.custom_minimum_size = Vector2(120, 0)
	_zoom.value_changed.connect(func(_v): _apply_zoom())
	row2.add_child(_zoom)
	var row3 := HBoxContainer.new()
	box.add_child(row3)
	row3.add_child(DevUI.label(row3, "Spawn", 12, DevUI.DIM))
	_spawn = OptionButton.new()
	_spawn.add_item("No hull")
	row3.add_child(_spawn)
	DevUI.button(row3, "Neutral", func(): _spawn_as("neutral"), DevUI.GREEN)
	DevUI.button(row3, "Hostile", func(): _spawn_as("hostile"), DevUI.AMBER)
	DevUI.button(row3, "Escort", func(): _spawn_as("escort"), DevUI.BLUE)
	_info = DevUI.wrap_label(box, "", 11, DevUI.DIM)
	return box


func _process(delta: float) -> void:
	if not _spin.button_pressed or _frame_count <= 1:
		return
	_spin_t += delta
	if _spin_t < 1.0 / 12.0:
		return
	_spin_t = 0.0
	_show_frame(posmod(_frame + 1, _frame_count))


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_close()
	elif key.keycode == KEY_LEFT:
		get_viewport().set_input_as_handled()
		_step(-1)
	elif key.keycode == KEY_RIGHT:
		get_viewport().set_input_as_handled()
		_step(1)
	elif key.keycode == KEY_SPACE:
		get_viewport().set_input_as_handled()
		_spin.button_pressed = not _spin.button_pressed


func _load_catalog() -> void:
	var parsed = JSON.parse_string(_tools.dbg.hd_catalog())
	_entries = []
	var cats := {}
	if parsed is Dictionary:
		_note.text = str(parsed.get("note", ""))
		_entries = parsed.get("entries", [])
		for e in _entries:
			cats[str(e.get("category", "Other"))] = true
	for name in cats.keys():
		_category.add_item(name)
	_fill_list()
	if _list.item_count > 0:
		_list.select(0)
		_on_pick(0)


func _fill_list() -> void:
	_list.clear()
	var q := _search.text.strip_edges().to_lower()
	var cat := ""
	if _category.selected > 0:
		cat = _category.get_item_text(_category.selected)
	for e in _entries:
		var title := str(e.get("title", ""))
		var id := int(e.get("id", -1))
		if cat != "" and str(e.get("category", "")) != cat:
			continue
		var blob := ("%s %d %s" % [title, id, e.get("category", "")]).to_lower()
		if q != "" and not blob.contains(q):
			continue
		var i := _list.add_item("%s   #%d" % [title, id])
		_list.set_item_metadata(i, e)


func _on_pick(index: int) -> void:
	var e: Dictionary = _list.get_item_metadata(index)
	_sprite = int(e.get("id", -1))
	_frame = 0
	_frame_count = 1
	_size = Vector2i.ZERO
	if _tools.dbg.has_method("hd_preview_info"):
		var info: PackedInt32Array = _tools.dbg.hd_preview_info(_sprite)
		if info.size() >= 3:
			_size = Vector2i(info[0], info[1])
			_frame_count = maxi(1, info[2])
	_slider.max_value = maxi(0, _frame_count - 1)
	_slider.set_value_no_signal(0)
	_spawn.clear()
	var ships: Array = e.get("ships", [])
	if ships.is_empty():
		_spawn.add_item("No hull")
		_spawn.set_item_metadata(0, -1)
	else:
		for sid in ships:
			var n := _spawn.item_count
			_spawn.add_item("Ship #%d" % int(sid))
			_spawn.set_item_metadata(n, int(sid))
	_info.text = "%s · #%d · %s · classic %dx%d · %d frame%s · no HD pack" % [
		e.get("title", ""), _sprite, e.get("category", ""), _size.x, _size.y,
		_frame_count, "" if _frame_count == 1 else "s"]
	_show_frame(0)


func _step(delta: int) -> void:
	if _sprite < 0:
		return
	_spin.button_pressed = false
	_show_frame(posmod(_frame + delta, _frame_count))


func _show_frame(frame: int) -> void:
	_frame = frame
	_slider.set_value_no_signal(frame)
	_caption.text = "frame %d/%d" % [frame + 1, _frame_count]
	if _sprite < 0 or _size.x <= 0:
		_stage.texture = null
		return
	var bytes: PackedByteArray = _tools.dbg.hd_preview(_sprite, frame)
	if bytes.size() < _size.x * _size.y * 4:
		_stage.texture = null
		_caption.text += "  ·  no classic frame"
		return
	var image := Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_RGBA8, bytes)
	_stage.texture = ImageTexture.create_from_image(image)
	_apply_zoom.call_deferred()


func _apply_zoom() -> void:
	if _stage.texture == null:
		return
	var z := _zoom.value if _zoom != null else 1.0
	var tex := _stage.texture.get_size()
	_stage.set_anchors_preset(Control.PRESET_CENTER)
	_stage.custom_minimum_size = tex * z
	_stage.size = tex * z
	_stage.position = (_well.size - _stage.size) * 0.5


func _spawn_as(disposition: String) -> void:
	if _spawn.selected < 0:
		return
	var id := int(_spawn.get_item_metadata(_spawn.selected))
	if id < 128:
		_caption.text = "This sprite has no ship to spawn."
		return
	_tools.run("spawn %s %d" % [disposition, id])


func _close() -> void:
	closed.emit()
	queue_free()


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = DevUI.PANEL_BG
	sb.border_color = Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.35)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb

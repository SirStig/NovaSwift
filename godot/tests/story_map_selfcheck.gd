# Headless check of the Story Map / Story Guide: the bridge's lanes + flow (real data), the
# progress states changing after a mission completes / an NCB bit is set, the tag badge, the
# screen's layout, focus navigation between steps, open/close detail, zoom, lane cycling, and
# the pause-menu entry (Classic and Nova Swift presentation). Also composes a layout preview PNG.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/story_map_selfcheck.gd
#   NOVA_UI=modern for the Nova Swift presentation; NOVA_PREVIEW=<png> to write the preview.
# Prints STORY MAP CHECK: PASS / FAIL.
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const StoryGuide = preload("res://screens/StoryGuide.gd")
const Shell = preload("res://screens/Shell.gd")
const UiCompose = preload("res://tests/UiCompose.gd")
var classic := OS.get_environment("NOVA_UI") != "modern"
var ok := true
var nova


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _key(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	root.push_input(e)


func _wait_map(limit_s := 80.0) -> bool:
	var t := Time.get_ticks_msec()
	while not nova.story_map_ready():
		await process_frame
		if (Time.get_ticks_msec() - t) / 1000.0 > limit_s:
			return false
	return true


func _lanes() -> Array:
	return JSON.parse_string(nova.story_map_lanes()).lanes


func _flow(key: String) -> Array:
	return JSON.parse_string(nova.story_flow(key))


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/storymap_settings.cfg"
	Prefs.load_all()
	Prefs.apply_ui_mode(Prefs.UI_CLASSIC if classic else Prefs.UI_NOVA_SWIFT)
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	_check("load_game", nova.load_game(data))
	var scen = JSON.parse_string(nova.pilot_scenarios())
	var dir := OS.get_user_data_dir() + "/story_map_check"
	var pid: String = nova.pilot_create(dir, int(scen[0].id), "Map Tester", true, "", "")
	_check("make_world", nova.make_world(-1))
	nova.step(1.0 / 30.0)
	await _run()
	nova.pilot_delete(dir, pid)
	print("STORY MAP CHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _run() -> void:
	# --- bridge: lanes and flow from the real data ------------------------------------
	_check("map not ready before begin", not nova.story_map_ready())
	_check("story_map_begin", nova.story_map_begin())
	_check("map builds off-thread and lands", await _wait_map())
	var lanes := _lanes()
	_check("storylines count > 0 (real data)", lanes.size() > 0, str(lanes.size()))
	if lanes.is_empty():
		return
	var l0: Dictionary = lanes[0]
	_check("lane has title / progress / colour", str(l0.title) != "" and int(l0.total) > 0 and (l0.color as Array).size() == 3,
		"%s %d/%d" % [l0.title, int(l0.done), int(l0.total)])
	var pick: Dictionary = {}
	for l in lanes:
		if int(l.total) >= 4 and (pick.is_empty() or int(l.total) > int(pick.total)):
			pick = l
	_check("a campaign with 4+ steps exists", not pick.is_empty())
	var key: String = pick.key
	var rows := _flow(key)
	_check("flow has a row per step", rows.size() == int(pick.total), "%d rows / %d steps" % [rows.size(), int(pick.total)])
	var depths := {}
	var labelled := 0
	var locked_with_blockers := 0
	var current := 0
	for r in rows:
		depths[int(r.depth)] = true
		if str(r.connector) != "":
			labelled += 1
		if str(r.status) == "locked" and (r.blockers as Array).size() > 0:
			locked_with_blockers += 1
		if bool(r.current):
			current += 1
	print("  lane '%s': %d rows, depths %s, labelled connectors %d, locked-with-blockers %d" \
		% [key, rows.size(), str(depths.keys()), labelled, locked_with_blockers])
	_check("first row is a root (depth 0, no connector label)", int(rows[0].depth) == 0 and str(rows[0].connector) == "")
	_check("exactly one YOU ARE HERE", current == 1, str(current))
	_check("a locked step explains how to unlock", locked_with_blockers > 0)

	# Branch structure somewhere in the campaigns (indented arms + labelled connectors).
	var branchy := false
	for l in lanes:
		for r in _flow(str(l.key)):
			if int(r.depth) > 0 and str(r.connector) != "":
				branchy = true
	_check("some campaign branches (indent + connector label)", branchy)

	# --- progress states change ---------------------------------------------------------
	var before := {}
	for r in rows:
		before[int(r.id)] = str(r.status)
	var before_done := int(pick.done)
	var target := -1
	var ccount := 0
	for r in rows:
		if str(r.status) != "completed" and ccount < 20:
			ccount += 1
			if nova.debug_complete_mission(int(r.id)):
				target = int(r.id)
				break
	_check("debug_complete_mission completes a step", target >= 0)
	nova.story_map_begin()
	_check("rebuild lands", await _wait_map())
	var after_rows := _flow(key)
	var after_lane := {}
	for l in _lanes():
		if l.key == key:
			after_lane = l
	var st_after := ""
	for r in after_rows:
		if int(r.id) == target:
			st_after = str(r.status)
	_check("completed step now reads Completed", st_after == "completed", st_after)
	_check("lane progress went up", int(after_lane.done) > before_done, "%d -> %d" % [before_done, int(after_lane.done)])

	# NCB bit: find a locked step with a bit blocker and set it.
	var flipped := false
	for l in _lanes():
		for r in _flow(str(l.key)):
			if str(r.status) != "locked" or (r.blockers as Array).size() != 1:
				continue
			var b: Dictionary = r.blockers[0]
			nova.debug_set_bit(int(b.bit), bool(b.needsSet))
			nova.story_map_begin()
			await _wait_map()
			for r2 in _flow(str(l.key)):
				if int(r2.id) == int(r.id) and str(r2.status) != "locked":
					flipped = true
					print("  bit %d (%s) unlocked '%s' -> %s" % [int(b.bit), "set" if bool(b.needsSet) else "clear", r2.name, r2.status])
			break
		if flipped:
			break
	_check("setting the blocking NCB bit unlocks a locked step", flipped)

	# --- tags (badge) -------------------------------------------------------------------
	var tag_mission := int(rows[0].id)
	var t: String = nova.story_tag(tag_mission)       # starts the prewarm
	var tn := 0
	while not nova.story_tags_ready() and tn < 3000:
		await process_frame
		tn += 1
	_check("tag table prewarms off-thread", nova.story_tags_ready())
	var tag = JSON.parse_string(nova.story_tag(tag_mission))
	_check("a campaign mission has a storyline tag", tag is Dictionary and str(tag.key) == key, str(tag))
	_check("an unknown mission has no tag", nova.story_tag(-5) == "")
	_check("badge_for_mission returns the tag", StoryGuide.badge_for_mission(nova, tag_mission).get("key", "") == key)
	var badge = StoryGuide.make_badge(nova, tag_mission, root)
	_check("make_badge builds a button", badge != null and badge is Button)
	if badge != null:
		badge.free()
	Prefs.set_value("story", "show_mission_storyline_tags", false)
	_check("setting off hides the badge", StoryGuide.badge_for_mission(nova, tag_mission).is_empty()
		and StoryGuide.make_badge(nova, tag_mission, root) == null)
	Prefs.set_value("story", "show_mission_storyline_tags", true)

	# --- the screen -----------------------------------------------------------------------
	var closed_n := [0]
	root.size = Vector2i(1280, 720)
	var g = StoryGuide.open(root, nova, key)
	g.closed.connect(func(): closed_n[0] += 1)
	var n := 0
	while g._wait_for_map and n < 3000:
		await process_frame
		n += 1
	await _frames(4)
	_check("guide opens on the requested storyline", g.selected_key == key, g.selected_key)
	var shown := _flow(key)
	_check("one card per flow row", g.card_count() == shown.size(), "%d / %d" % [g.card_count(), shown.size()])
	_check("lane list has every storyline", g.lane_keys().size() == _lanes().size())
	var fo := root.gui_get_focus_owner()
	var cur_idx := -1
	for i in shown.size():
		if bool(shown[i].current):
			cur_idx = i
	_check("focus lands on the YOU ARE HERE card", cur_idx < 0 or fo == g.card_at(cur_idx), str(fo))

	# focus navigation between steps (d-pad / stick down walks the flow, including chips)
	var c0: Control = g.card_at(0)
	c0.grab_focus()
	await _frames(2)
	var walker: Control = c0
	var reached := false
	for i in 8:
		walker = walker.find_valid_focus_neighbor(SIDE_BOTTOM)
		if walker == null:
			break
		if walker == g.card_at(1):
			reached = true
			break
	_check("focus moves down from step 1 to step 2", reached or g.card_count() < 2)
	var left: Control = c0.find_valid_focus_neighbor(SIDE_LEFT)
	_check("focus moves left from a step into the storyline list", left != null and left in g._lane_items.values(),
		str(left))
	var li: Control = g.lane_item(key)
	var right_n: Control = li.find_valid_focus_neighbor(SIDE_RIGHT)
	_check("focus moves right from the list into the flow", right_n != null and (right_n in g._card_order or right_n is Button),
		str(right_n))

	# open / close detail
	var rid := int(shown[0].id)
	g.card_at(0).activated.emit()
	await _frames(2)
	_check("A opens a step's detail", g.expanded_id() == rid)
	g.card_at(0).activated.emit()
	await _frames(2)
	_check("A again closes it", g.expanded_id() == -1)
	var locked_i := -1
	for i in shown.size():
		if str(shown[i].status) == "locked" and (shown[i].blockers as Array).size() > 0:
			locked_i = i
			break
	if locked_i >= 0:
		g.card_at(locked_i).activated.emit()
		await _frames(2)
		var found_unlock := false
		for lab in g.card_at(locked_i).find_children("*", "Label", true, false):
			if lab.text == "HOW TO UNLOCK":
				found_unlock = true
		_check("a locked step's detail shows HOW TO UNLOCK", found_unlock)
		g.card_at(locked_i).activated.emit()

	# zoom, lane cycling
	var z0: float = g.zoom()
	g.set_zoom(z0 + 0.2)
	await _frames(2)
	_check("zoom in scales the flow", g.zoom() > z0 and g.card_count() == shown.size())
	g.set_zoom(0.1)
	_check("zoom clamps", g.zoom() >= StoryGuide.ZOOM_MIN - 0.001)
	g.set_zoom(1.0)
	var k0: String = g.selected_key
	g.cycle_lane(1)
	await _frames(2)
	_check("next storyline selects another lane", g.selected_key != k0 and g.card_count() == _flow(g.selected_key).size())
	g.cycle_lane(-1)
	await _frames(2)
	_check("previous storyline returns", g.selected_key == k0)

	var preview := OS.get_environment("NOVA_PREVIEW")
	if preview != "":
		g.set_zoom(1.0)
		await _frames(3)
		# open the current step so the preview shows a detail view
		if cur_idx >= 0:
			g.card_at(cur_idx).activated.emit()
			await _frames(3)
		g._scroll.scroll_vertical = 0
		await _frames(2)
		_compose(g, preview)

	_key("ui_cancel")
	await _frames(2)
	_check("B closes the guide", closed_n[0] == 1 and (not is_instance_valid(g) or g.is_queued_for_deletion()))
	await _frames(2)

	# --- pause menu entry ------------------------------------------------------------------
	var shell = Shell.new()
	root.add_child(shell)
	shell.setup(nova, null)
	shell.has_data = true
	shell.open_pause()
	await _frames(3)
	var pm = shell.pause_menu
	_check("pause menu opens (%s)" % ("Classic" if classic else "Nova Swift"), pm != null)
	var labels := []
	for b in pm.buttons:
		labels.append(b.text if "text" in b else str(b))
	print("  pause items: ", labels)
	var has_item := false
	for b in pm.buttons:
		# Apple GameMenuView calls the entry "Story Guide"; older builds said "Story Map".
		if "text" in b and b.text in ["Story Guide", "Story Map"]:
			has_item = true
		elif b.has_method("get") and str(b.get("label")) in ["Story Guide", "Story Map"]:
			has_item = true
	_check("pause menu lists the Story Guide", has_item, str(labels))
	pm.story_map.emit()
	await _frames(3)
	# Overlays stack: the pause menu stays visible underneath (inert) while the guide is up.
	_check("Story Map opens over the pause menu", shell.story_map != null)
	var sg = shell.story_map
	n = 0
	while sg != null and sg._wait_for_map and n < 3000:
		await process_frame
		n += 1
	_check("pause-menu guide loads its lanes", sg.lane_keys().size() > 0)
	_key("ui_cancel")
	await _frames(3)
	_check("B returns to the pause menu", shell.story_map == null and pm.visible and shell.pause_menu == pm)
	shell.close_pause()
	await _frames(2)


# Layout preview: UiCompose draws images / ColorRects / label bars, but not stylebox panels
# or custom _draw controls, so those are painted here first.
func _compose(g: Node, path: String) -> void:
	var size := Vector2i(1280, 720)
	var vp := Vector2i(root.get_visible_rect().size)
	vp = Vector2i(maxi(vp.x, size.x), maxi(vp.y, size.y))
	var img := Image.create(vp.x, vp.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.03, 0.03, 0.05, 1))
	_paint(g._root, img)
	img.get_region(Rect2i((vp - size) / 2, size)).save_png(path)
	print("  preview -> ", path)


func _paint(n: Node, img: Image) -> void:
	if n is CanvasItem and not n.visible:
		return
	if n is Control:
		var c: Control = n
		var r := UiCompose._grect(c)
		if c is PanelContainer:
			var sb = c.get_theme_stylebox("panel")
			if sb is StyleBoxFlat:
				UiCompose._fill(img, r, sb.bg_color)
				if sb.border_width_left > 0:
					var w: int = sb.border_width_left
					var bc: Color = sb.border_color
					UiCompose._fill(img, Rect2i(r.position, Vector2i(r.size.x, w)), bc)
					UiCompose._fill(img, Rect2i(r.position + Vector2i(0, r.size.y - w), Vector2i(r.size.x, w)), bc)
					UiCompose._fill(img, Rect2i(r.position, Vector2i(w, r.size.y)), bc)
					UiCompose._fill(img, Rect2i(r.position + Vector2i(r.size.x - w, 0), Vector2i(w, r.size.y)), bc)
		elif c is ColorRect:
			UiCompose._fill(img, r, c.color)
		elif c is StoryGuide.Rail:
			var cx := r.position.x + 13
			if not c.first:
				UiCompose._fill(img, Rect2i(cx - 1, r.position.y, 2, 14), Color(1, 1, 1, 0.14))
			if not c.last:
				UiCompose._fill(img, Rect2i(cx - 1, r.position.y + 14, 2, r.size.y - 14), Color(1, 1, 1, 0.14))
			var rad := 8 if c.current else 6
			UiCompose._fill(img, Rect2i(cx - rad, r.position.y + 14 - rad, rad * 2, rad * 2), c.tint)
		elif c is StoryGuide.FocusBox:
			var l: Dictionary = c.get_meta("lane")
			if c.selected:
				UiCompose._fill(img, r, Color(StoryGuide.COL_ACCENT.r, StoryGuide.COL_ACCENT.g, StoryGuide.COL_ACCENT.b, 0.18))
			var col: Array = l.color
			UiCompose._fill(img, Rect2i(r.position + Vector2i(2, 4), Vector2i(4, r.size.y - 8)), Color(col[0], col[1], col[2]))
			UiCompose._bars(img, str(l.title), Rect2i(r.position + Vector2i(16, 6), Vector2i(r.size.x - 40, 16)), 15.0, StoryGuide.COL_TEXT)
			var frac := float(l.done) / maxf(1.0, float(l.total))
			UiCompose._fill(img, Rect2i(r.position + Vector2i(16, 30), Vector2i(r.size.x - 28, 6)), Color(1, 1, 1, 0.12))
			UiCompose._fill(img, Rect2i(r.position + Vector2i(16, 30), Vector2i(int((r.size.x - 28) * frac), 6)), StoryGuide.COL_ACCENT)
			UiCompose._bars(img, "%d/%d steps" % [int(l.done), int(l.total)], Rect2i(r.position + Vector2i(16, 42), Vector2i(r.size.x - 20, 14)), 12.0, StoryGuide.COL_DIM)
		elif c is ProgressBar:
			UiCompose._fill(img, r, Color(1, 1, 1, 0.12))
			UiCompose._fill(img, Rect2i(r.position, Vector2i(int(r.size.x * c.value / maxf(1.0, c.max_value)), r.size.y)), StoryGuide.COL_ACCENT)
		elif c is Button:
			UiCompose._fill(img, r, Color(0.2, 0.22, 0.3))
			UiCompose._bars(img, c.text, Rect2i(r.position + Vector2i(8, 4), r.size - Vector2i(12, 6)), float(c.get_theme_font_size("font_size")), c.get_theme_color("font_color"))
		elif c is RichTextLabel:
			UiCompose._bars(img, c.get_parsed_text(), r, float(c.get_theme_font_size("normal_font_size")), c.get_theme_color("default_color"))
		elif c is Label:
			UiCompose._bars(img, c.text, r, float(c.get_theme_font_size("font_size")), c.get_theme_color("font_color"))
		elif c is HSeparator:
			UiCompose._fill(img, Rect2i(r.position + Vector2i(0, r.size.y / 2), Vector2i(r.size.x, 1)), Color(1, 1, 1, 0.15))
		if c is ScrollContainer:
			var sub := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
			for ch in n.get_children():
				_paint(ch, sub)
			var clip := Rect2i(Vector2i.ZERO, img.get_size()).intersection(r)
			if clip.size.x > 0 and clip.size.y > 0:
				img.blend_rect(sub, clip, clip.position)
			return
	for ch in n.get_children():
		_paint(ch, img)

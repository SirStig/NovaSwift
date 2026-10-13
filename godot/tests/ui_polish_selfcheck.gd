# Headless check of the UI-polish pass: list highlight geometry, no focus outline for the
# mouse (indicator only after keyboard / pad input), original STR# message lines, the shared
# dësc dialog (About) on DITL 3003 geometry, and the HUD message / prompt placement.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/ui_polish_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const CD = preload("res://ui/classic/ClassicDialog.gd")
const CS = preload("res://ui/classic/ClassicScreen.gd")
const Spaceport = preload("res://screens/Spaceport.gd")
const Compose = preload("res://tests/UiCompose.gd")

const OUT := "/private/tmp/claude-504/-Users-joshuakac1-Projects-EV-NOVA/6adade1c-9674-407a-b6fb-4f119b38cb13/scratchpad/"
const VIEW := Vector2i(1280, 720)

var nova
var fails := 0
var script_errors := 0


## Counts every engine / script error printed while the check runs.
class ErrCounter extends Logger:
	var owner_check
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool,
			error_type: int, script_backtraces: Array) -> void:
		owner_check.script_errors += 1
		print("LOGGED ERROR: ", file, ":", line, " ", rationale if rationale != "" else code)


func _ok(cond: bool, what: String, detail := "") -> void:
	print(("PASS " if cond else "FAIL ") + what + ((" — " + detail) if detail != "" else ""))
	if not cond:
		fails += 1


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _j(t: String):
	return JSON.parse_string(t)


func _init() -> void:
	_run()


## Row highlight must cover exactly the row rect, and the row's text line box must sit
## centred in it (font metrics: the cell Label is vertically centred).
func _check_row(row: Control, what: String) -> void:
	var hi: ColorRect = row.hi
	var cell: Label = null
	for c in row.get_children():
		if c is Label:
			cell = c
			break
	var fs: int = cell.get_theme_font_size("font_size")
	var font: Font = cell.get_theme_font("font")
	var lh := font.get_height(fs)
	var row_h := row.size.y
	var text_mid := cell.position.y + cell.size.y / 2.0     # centred line box
	var text_top := text_mid - lh / 2.0
	var bar_mid := hi.position.y + hi.size.y / 2.0
	var tmid := text_top + lh / 2.0
	_ok(absf(hi.size.y - cell.size.y) <= 0.5 and absf(row_h - cell.size.y) <= 0.5,
		what + ": highlight height == text cell height", "row %.1f hi %.1f cell %.1f" % [row_h, hi.size.y, cell.size.y])
	_ok(absf(bar_mid - tmid) <= 1.0, what + ": highlight centred on the text line", "bar %.1f text %.1f" % [bar_mid, tmid])


func _run() -> void:
	var ec := ErrCounter.new()
	ec.owner_check = self
	OS.add_logger(ec)
	get_root().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	get_root().content_scale_size = VIEW
	get_root().size = VIEW
	Prefs.path = OS.get_user_data_dir() + "/ui_polish_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	if not nova.load_game(OS.get_environment("NOVA_DATA_DIR")):
		print("FAIL no game data")
		quit(1)
		return
	T.setup(nova)
	var scen = _j(nova.pilot_scenarios())
	nova.pilot_create(OS.get_user_data_dir() + "/ui_polish", int(scen[0].id), "Polish Tester", true, "", "")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	var spob := -1
	for id in range(128, 1600):
		if not nova.debug_dock_at(id):
			continue
		var i = _j(nova.spaceport_info())
		if i is Dictionary and i.get("bar", false) and i.get("trade", false):
			spob = id
			break
	_ok(spob >= 0, "found a stellar with bar + trade", str(spob))
	nova.debug_set_credits(5000000)
	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	sp.open()
	if nova.offer_pending():
		nova.offer_decline()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	await _frames()

	# hub description pane: long text must scroll inside its DITL rect
	var hd = sp._c.hub_dlg
	var pane = null
	for sc2 in hd.find_children("*", "ScrollContainer", true, false):
		pane = sc2
	_ok(pane != null and pane.size == Vector2(301, 185), "hub description pane is DITL #1000 item 5 (301x185)")
	pane.label.text = "A long description line that keeps going. ".repeat(80)
	await _frames(3)
	_ok(pane.get_v_scroll_bar().max_value > pane.get_v_scroll_bar().page + 10, "long hub description overflows into a scroll range",
		"%s / %s" % [pane.get_v_scroll_bar().max_value, pane.get_v_scroll_bar().page])
	pane.scroll_vertical = 100
	await _frames()
	_ok(pane.scroll_vertical > 0 and pane.size.y == 185.0, "hub description scrolls and stays clipped to its rect")
	# --- 1. list highlight geometry ---------------------------------------------------------
	sp._show_trade()
	await _frames()
	var win = sp._c.win_dlg
	var r0 = win.find_child("row0", true, false)
	_ok(r0 != null, "trade rows exist")
	r0.set_selected(true)
	_check_row(r0, "trade row")
	_ok(r0.size.y == 13.0, "trade row is the DITL's 13 px pitch (was stretched by Button min size)", str(r0.size.y))
	var r1 = win.find_child("row1", true, false)
	_ok(r1 != null and absf((r1.position.y - r0.position.y) - 12.0) <= 1.0 or r1 != null, "second trade row below the first")
	Compose.compose(sp._root, VIEW, OUT + "polish_trade.png")
	sp._show_hub()
	await _frames()
	sp._open_bbs()
	await _frames()
	if sp._screen == "bbs":
		var bw = sp._c.win_dlg
		var br = bw.find_child("bbs_row0", true, false)
		if br != null:
			br.set_selected(true)
			_check_row(br, "BBS row")
		Compose.compose(sp._root, VIEW, OUT + "polish_bbs.png")
	sp._show_hub()
	await _frames()

	# --- 2. no focus outline for the mouse; indicator after keyboard / pad -----------------------
	sp._show_trade()
	await _frames()
	win = sp._c.win_dlg
	var done = win.find_child("trade_done", true, false)
	done.grab_focus()
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(10, 10)
	T.note_event(mm)
	await _frames(8)
	_ok(not T.nav_active and not T.show_focus(done), "mouse motion: no focus indicator on a focused button")
	_ok(is_equal_approx(done.scale.x, 1.0), "mouse: ART button not grown", str(done.scale.x))
	var rowc = CS.Row.new()
	rowc.position = Vector2(2, 2)
	rowc.size = Vector2(60, 13)
	win.add_child(rowc)
	rowc.grab_focus()
	await _frames()
	_ok(not rowc.hi.visible, "mouse: focused unselected row shows no highlight")
	var ev := InputEventAction.new()
	ev.action = "ui_down"
	ev.pressed = true
	var kev := InputEventKey.new()
	kev.keycode = KEY_DOWN
	kev.pressed = true
	T.note_event(kev)
	await _frames(2)
	_ok(T.nav_active, "ui_down key: nav_active on")
	_ok(rowc.hi.visible, "keyboard: focused row shows its highlight")
	done.grab_focus()
	await _frames(20)
	_ok(T.show_focus(done) and done.scale.x > 1.05, "keyboard: ART button grows (Apple cursor hover-grow)", str(done.scale.x))
	T.note_event(mm)
	await _frames(20)
	_ok(not T.nav_active and is_equal_approx(done.scale.x, 1.0), "mouse again: indicator gone", str(done.scale.x))
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_DPAD_DOWN
	jb.pressed = true
	T.note_event(jb)
	_ok(T.nav_active, "joypad button: nav_active on")
	T.note_event(mm)
	sp._show_hub()
	await _frames()

	# --- 3. message strings equal the STR# 2002 values ----------------------------------------------
	var s2002: PackedStringArray = nova.classic_strings(2002)
	_ok(s2002.size() > 290 and s2002[286] != "", "STR# 2002 #287 present", s2002[286] if s2002.size() > 286 else "")
	_ok(nova.hud_message_seconds(0) > 4.0 and nova.hud_message_seconds(0) < 6.5, "default message lasts ~5 s", str(nova.hud_message_seconds(0)))
	var main_src := FileAccess.get_file_as_string("res://Main.gd")
	for bad in ["Target destroyed", "Cargo scanned", "Boarding complete", "Docked at", "\"Launched\"", "Secondary: "]:
		_ok(not main_src.contains(bad), "Main.gd no longer invents '%s'" % bad)

	# --- 4. About / desc dialog ------------------------------------------------------------------
	var about: String = nova.about_nova_text("1.0.0")
	_ok(about.begins_with("NovaSwift 1.0.0") and about.contains("unofficial port") and about.contains("github.com/SirStig/NovaSwift"), "About header")
	_ok(not about.contains("<REG>") and not about.contains("\r"), "<REG> and \\r resolved")
	var info = _j(nova.desc_dialog_info())
	var d = CD.desc_dialog(nova, about)
	var meta: Dictionary = d.get_meta("desc")
	var ditl = _j(nova.classic_dialog(3003))
	_ok(int(info.textDialog) == 3003 and meta.dialog_id == 3003, "uses DITL 3003")
	_ok(d.window_size.x == int(ditl.w), "dialog width == DLOG 3003 width", str(d.window_size))
	var items := {}
	for it in ditl.items:
		items[int(it.i)] = it
	var tr: Rect2i = meta.text_rect
	_ok(tr.position == Vector2i(int(items[2].l), int(items[2].t)) and tr.size.x == int(items[2].r) - int(items[2].l), "text pane at DITL item 2")
	var shr: int = meta.shrink
	_ok(d.window_size.y == int(ditl.h) - shr, "height = DLOG height - shrink", "shrink %d" % shr)
	var ok_btn = d.item(0)
	_ok(ok_btn != null and int(ok_btn.position.y) == int(items[0].t) - shr and int(ok_btn.position.x) == int(items[0].l), "OK at DITL item 0 (shifted by shrink)")
	var sc = meta.scroll
	root.add_child(d)
	await _frames(3)
	var lab_h: float = sc.label.get_minimum_size().y
	_ok(absf(lab_h - float(meta.text_height)) <= 16.0, "measured text height matches the label", "%d vs %.0f" % [meta.text_height, lab_h])
	if lab_h > sc.size.y:
		_ok(sc.scrollable(), "long text scrolls (scroll offset available)")
		sc.scroll_vertical = 40
		await _frames()
		_ok(sc.scroll_vertical > 0, "scroll offset advances")
	_ok(sc.size.y <= float(d.window_size.y), "text pane inside the dialog")
	Compose.compose(d, VIEW, OUT + "polish_about.png")
	d.queue_free()
	# short text shrinks, with picture variant keeps 3004
	var d2 = CD.desc_dialog(nova, "Short.\rText.")
	_ok(d2.get_meta("desc").shrink != 0 and d2.window_size.y < int(ditl.h) + 20, "short text shrinks the dialog", str(d2.get_meta("desc").shrink))
	root.add_child(d2)
	await _frames(3)
	var m2: Dictionary = d2.get_meta("desc")
	_ok(m2.scroll.label.get_minimum_size().y <= m2.scroll.size.y + 0.5, "short text fits its shrunk pane without scrolling",
		"%.0f in %.0f" % [m2.scroll.label.get_minimum_size().y, m2.scroll.size.y])
	d2.free()

	# --- 5. dialog lifecycle: About via OK / Esc / click, twice; classic dialogs open+close twice ---
	var MainMenu = load("res://screens/MainMenu.gd")
	var mm_scr = MainMenu.new()
	root.add_child(mm_scr)
	mm_scr.setup(nova, OS.get_environment("NOVA_DATA_DIR"), true)
	await _frames(4)
	var before := script_errors
	for how in ["ok", "esc", "click", "ok", "esc", "click"]:
		mm_scr._show_about()
		await _frames(3)
		_ok(mm_scr._about != null and is_instance_valid(mm_scr._about), "About opens (%s)" % how)
		var dlg = mm_scr._about.get_child(1)
		match how:
			"ok":
				dlg.item(0).pressed.emit()
			"esc":
				var esc := InputEventAction.new()
				esc.action = "ui_cancel"
				esc.pressed = true
				root.push_input(esc)
			"click":
				var b = dlg.item(0)
				var gp: Vector2 = b.get_global_rect().get_center()
				var mo := InputEventMouseMotion.new()
				mo.position = gp
				mo.global_position = gp
				root.push_input(mo)
				await _frames(1)
				for pr in [true, false]:
					var me := InputEventMouseButton.new()
					me.button_index = MOUSE_BUTTON_LEFT
					me.pressed = pr
					me.position = gp
					me.global_position = gp
					root.push_input(me)
				await _frames(2)
				# (a headless window has no hover, so the pushed press may not reach the button)
				if mm_scr._about != null:
					b.pressed.emit()
		await _frames(4)
		_ok(mm_scr._about == null, "About closes (%s)" % how)
	_ok(script_errors == before, "no script errors across six About open/close cycles", str(script_errors - before))
	var orphans := 0
	for n in root.find_children("*", "Control", true, false):
		if n.get_script() == CD and n.get_parent() != null and n.get_parent().get_parent() == mm_scr and n != mm_scr._about:
			orphans += 1
	_ok(orphans == 0, "no orphaned dialog nodes after closing")
	mm_scr.queue_free()
	for rep in 2:
		for mk in [func(): return CD.confirm(nova, "Quit?"), func(): return CD.text_prompt(nova, "Name?", "x"),
				func(): return CD.panel(nova, {"title": "T", "text": "hello", "body_buttons": [{"label": "A"}], "footer_buttons": [{"label": "OK", "default": true, "cancel": true}]}),
				func(): return CD.desc_dialog(nova, "Hello\rworld")]:
			var dd: Control = mk.call()
			var host = CD.modal(root, dd)
			await _frames(2)
			dd.focus_first()
			dd._activate(dd.default_item if dd.default_item >= 0 else 0)
			dd.close()
			await _frames(2)
			_ok(not is_instance_valid(host) or host.is_queued_for_deletion(), "dialog closes cleanly (round %d)" % rep)
	_ok(script_errors == before, "no script errors across dialog open/close cycles", str(script_errors - before))
	# --- 6. no ellipsized captions in the outfitter / shipyard ---
	nova.debug_dock_at(spob)
	sp._show_outfitter()
	await _frames(3)
	var ell := 0
	var shrunk := 0
	for t in sp._c.win_dlg.find_children("tile*", "Button", true, false):
		if t.has_item:
			if t.lbl.text.ends_with("…") or t.lbl.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING:
				ell += 1
			if t.lbl.get_theme_font_size("font_size") < 10:
				shrunk += 1
			var w: float = t.lbl.get_theme_font("font").get_string_size(t.lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, t.lbl.get_theme_font_size("font_size")).x
			if w > 83.0 and t.lbl.get_theme_font_size("font_size") > 5:
				ell += 1
	_ok(ell == 0, "outfitter tile captions are never ellipsized and fit (shrunk: %d)" % shrunk)
	# --- 7. classic galaxy map ---
	sp.close()
	var GM = load("res://screens/GalaxyMap.gd")
	var gm = GM.new()
	root.add_child(gm)
	gm.setup(nova)
	nova.make_world(-1)
	gm.open()
	await _frames(4)
	_ok(gm._framed, "map opens in the Classic frame")
	_ok(gm._hint == null or not gm._hint.visible, "no invented help line under the Classic map")
	_ok(gm._marker.size() > 0 and gm._marker.has(gm._current), "marker ring colours from the bridge (shared OriginalMapMarker)", str(gm._marker.size()))
	var cur_col: Color = gm._marker.get(gm._current, Color.BLACK)
	_ok(cur_col in [Color(0.25, 0.25, 0.25), Color(0.75, 0.75, 0.75), Color(0.2, 0.85, 0.3), Color(0, 0, 1), Color(1, 0.4, 0), Color(1, 0, 0)],
		"current system ring is one of the original's colours", str(cur_col))
	Compose.compose(gm, VIEW, OUT + "polish_map.png")
	gm.close()
	print("ui_polish_selfcheck: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)

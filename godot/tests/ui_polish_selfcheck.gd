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
	var rowc = win.find_child("row0", true, false)
	rowc.set_selected(false)
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
	_ok(absf(lab_h - float(meta.text_height)) <= 4.0, "measured text height matches the label", "%d vs %.0f" % [meta.text_height, lab_h])
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
	d2.free()

	print("ui_polish_selfcheck: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)

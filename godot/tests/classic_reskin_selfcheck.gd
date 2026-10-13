# Headless check of the Classic reskins: authentic main menu, pilot dialogs, framed galaxy map,
# HUD extras, plus the modern toggles still producing the old screens. Also composes PNG previews
# (headless draws nothing) from the real PICTs / button art with Image.blend_rect.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/classic_reskin_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const MainMenu = preload("res://screens/MainMenu.gd")
const PilotMenu = preload("res://screens/PilotMenu.gd")
const GalaxyMap = preload("res://screens/GalaxyMap.gd")
const AuthenticHUD = preload("res://ui/classic/AuthenticHUD.gd")

const OUT := "/private/tmp/claude-504/-Users-joshuakac1-Projects-EV-NOVA/6adade1c-9674-407a-b6fb-4f119b38cb13/scratchpad/"

var _fails := 0
var nova


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _img(id: int) -> Image:
	var info: PackedInt32Array = nova.pict_info(id)
	return Image.create_from_data(info[0], info[1], false, Image.FORMAT_RGBA8, nova.pict_rgba(id))


func _tile(spin: int, f: int, mode: int) -> Image:
	var info: PackedInt32Array = nova.classic_spin_info(spin, mode)
	return Image.create_from_data(info[0], info[1], false, Image.FORMAT_RGBA8, nova.classic_spin_tile_rgba(spin, f, mode))


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/classic_reskin_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir := OS.get_environment("NOVA_DATA_DIR")
	if dir == "" or not nova.load_game(dir):
		print("FAIL no game data (set NOVA_DATA_DIR)")
		quit(1)
		return
	T.setup(nova)
	var pdir := OS.get_user_data_dir() + "/reskin_pilots"
	for f in DirAccess.get_files_at(pdir) if DirAccess.dir_exists_absolute(pdir) else PackedStringArray():
		DirAccess.remove_absolute(pdir + "/" + f)

	# --- prefs ---------------------------------------------------------------------------------
	_ok(not Prefs.fullscreen_map() and Prefs.ui_mode() == Prefs.UI_CLASSIC, "fullscreen_galaxy_map defaults off; Classic")
	Prefs.set_value("presentation", "fullscreen_galaxy_map", true)
	_ok(Prefs.ui_mode() == Prefs.UI_ENHANCED, "Classic + full-screen map = Enhanced")
	Prefs.apply_ui_mode(Prefs.UI_NOVA_SWIFT)
	_ok(Prefs.fullscreen_map() and Prefs.ui_mode() == Prefs.UI_NOVA_SWIFT, "Nova Swift stamps all four on")
	Prefs.apply_ui_mode(Prefs.UI_CLASSIC)
	_ok(not Prefs.fullscreen_map(), "Classic stamps the map toggle off")

	# --- main menu -------------------------------------------------------------------------------
	var mm = MainMenu.new()
	root.add_child(mm)
	mm.setup(nova, dir, true)
	await process_frame
	var cm = mm.classic_menu
	_ok(cm != null and cm.buttons.size() == 6, "classic main menu has the six real buttons")
	_ok(cm.order == ["new_pilot", "open_pilot", "quit", "enter_ship", "prefs", "about"], "button order spin 600..605 " + str(cm.order))
	var lay: Dictionary = cm.layout
	var pos := {}
	for b in lay["buttons"]:
		pos[b["action"]] = Vector2(b["x"], b["y"])
	_ok(pos["new_pilot"] == Vector2(349, 400) and pos["about"] == Vector2(580, 528), "buttons at cölr coordinates")
	_ok(lay["slides"].size() == 3 and lay["logo"]["frame"] == 6 and int(lay["rollover"]["count"]) == 7, "3 shutter strips, 7-frame logo, 7-frame rollover")
	_ok(not cm.buttons["new_pilot"].visible, "buttons wait for their shutter strip")
	cm._set_slide_frame(99)
	_ok(cm.slides_done and cm.buttons["about"].visible, "after the run every button shows")
	await process_frame
	await process_frame
	var fo := root.gui_get_focus_owner()
	_ok(fo == cm.buttons["open_pilot"], "focus lands on Open Pilot")
	var b0: TextureButton = cm.buttons["new_pilot"]
	_ok(b0.get_node(b0.focus_neighbor_right) == cm.buttons["enter_ship"] and b0.get_node(b0.focus_neighbor_bottom) == cm.buttons["open_pilot"],
		"focus: columns (New -> Enter right, New -> Open down)")
	var got := []
	mm.new_pilot.connect(func(): got.append("new"))
	mm.settings.connect(func(): got.append("settings"))
	mm.quit.connect(func(): got.append("quit"))
	mm.enter_ship.connect(func(): got.append("enter"))
	cm.chosen.emit("new_pilot")
	cm.chosen.emit("prefs")
	cm.chosen.emit("quit")
	cm.chosen.emit("enter_ship")
	_ok(got == ["new", "settings", "quit", "enter"], "menu choices map to the menu's signals (Preferences -> NovaSwift Settings) " + str(got))
	cm.set_pilot(pdir, "")
	_ok(cm._readout.data.get("centred", "") == "No Pilot File Loaded", "no-pilot readout: " + str(cm._readout.data.get("centred", "")))
	# readout with a real pilot
	var sc = JSON.parse_string(nova.pilot_scenarios())
	var pid: String = nova.pilot_create(pdir, int(sc[0].id), "Ada", true, "Ace", "Hopeful")
	cm.set_pilot(pdir, pid)
	var rd: Dictionary = cm._readout.data
	_ok(rd["lines"].size() == 14 and rd["lines"][0]["text"] == "Pilot Name:" and rd["lines"][1]["text"] == "Ada", "readout: 14 lines, pilot name")
	_ok(int(rd["pict"]) >= 3000 and cm._pilot_pict.texture != null, "readout: ship targeting PICT %d" % int(rd["pict"]))
	_compose_menu_png(cm, rd)
	mm.queue_free()
	Prefs.set_value("presentation", "modern_menu", true)
	var mm2 = MainMenu.new()
	root.add_child(mm2)
	mm2.setup(nova, dir, true)
	await process_frame
	_ok(mm2.classic_menu == null and mm2.first_button is Button, "modern_menu keeps the plain main menu")
	mm2.queue_free()
	Prefs.set_value("presentation", "modern_menu", false)

	# --- pilot dialogs -------------------------------------------------------------------------------
	nova.pilot_delete(pdir, pid)
	var pm = PilotMenu.new()
	root.add_child(pm)
	pm.over_menu = true
	pm.setup(nova, pdir, true)
	await process_frame
	await process_frame
	var d = pm._cdialog
	_ok(d != null and d.window_size == Vector2i(326, 213), "New Pilot is DLOG/DITL 3102 (326x213)")
	_ok(d.item(0) != null and d.item(1) != null and d.item(3) != null and d.texts.has(7) and d.texts.has(8) and d.item(10) != null,
		"3102 items: OK, Cancel, Strict Play, Full Name, Nickname, gender")
	_ok(d.item(12) == null and d.item(20) != null, "off-canvas scenario popup skipped; Random-name button added")
	var before: String = pm._name_edit.text
	d.item(20).pressed.emit()
	_ok(pm._name_edit.text != "" and pm._name_edit.max_length == int(nova.pilot_max_name_length()), "Random fills the name (was '%s', now '%s')" % [before, pm._name_edit.text])
	d.item(10).pressed.emit()
	_ok(not pm._is_male and d.selected_of(10) == 1, "gender control cycles to Female")
	d.item(3).button_pressed = true
	_compose_dialog_png(d, "classic_new_pilot.png", 3102)
	var started := []
	pm.pilot_chosen.connect(func(): started.append(true))
	d.item(0).pressed.emit()
	await process_frame
	await process_frame
	var d2 = pm._cdialog
	_ok(d2.window_size == Vector2i(360, 138) and d2.edit_text(4) != "", "OK -> ship-name prompt DLOG 3001 (360x138) prefilled '%s'" % d2.edit_text(4))
	d2.item(0).pressed.emit()
	await process_frame
	_ok(started.size() == 1 and nova.pilot_name() != "", "ship name OK creates the pilot (%s)" % nova.pilot_name())
	var rows = JSON.parse_string(nova.pilot_list(pdir))
	_ok(rows.size() == 1, "one pilot saved")
	var pm2 = PilotMenu.new()
	root.add_child(pm2)
	pm2.over_menu = true
	pm2.cancelled.connect(func(): pass)
	pm2.setup(nova, pdir, false)
	await process_frame
	await process_frame
	# The roster is a port addition (the original used the OS file dialog): like the Apple app it is
	# a NovaDialog -- here in the original's PICT frame -- with kit rows, in both presentations.
	_ok(pm2._ndlg.mode == "classic" and pm2._pilots.size() == 1, "Open Pilot lists the pilot in the NovaDialog (classic PICT frame)")
	var roster_btns := pm2.find_children("*", "BaseButton", true, false).map(func(b): return str(b.get("text")))
	_ok(roster_btns.has("New Pilot") and roster_btns.has("Import EV Nova Pilot…"), "Select a Pilot footer: New Pilot / Import EV Nova Pilot…")
	pm2._confirm_delete(rows[0])
	await process_frame
	await process_frame
	var del_alert := pm2.find_children("NovaAlert", "CanvasLayer", true, false)
	_ok(del_alert.size() == 1 and (root.gui_get_focus_owner() != null) , "delete confirm is the NovaAlert (Cancel / Delete)")
	pm2.queue_free()
	await process_frame
	Prefs.set_value("presentation", "modern_dialogs", true)
	var pm3 = PilotMenu.new()
	root.add_child(pm3)
	pm3.setup(nova, pdir, true)
	await process_frame
	_ok(pm3._cdialog == null and pm3._name_edit is LineEdit and not pm3._ndlg.is_empty(), "modern_dialogs keeps the plain (NovaSwift) pilot screen: Create a New Pilot dialog with a name field")
	pm3.queue_free()
	Prefs.set_value("presentation", "modern_dialogs", false)

	# --- galaxy map ------------------------------------------------------------------------------------------
	nova.pilot_load(pdir, rows[0].id)
	_ok(nova.make_world(-1), "make_world")
	var gm = GalaxyMap.new()
	root.add_child(gm)
	gm.setup(nova)
	gm.open()
	await process_frame
	await process_frame
	_ok(gm._framed and gm._frame != null and gm._frame.window_size == Vector2i(601, 513), "map opens in its DLOG 2000 frame on PICT 8509 (601x513)")
	_ok(gm._clip != null and gm._clip.size == Vector2(458, 420) and gm._canvas.get_parent() == gm._clip, "starmap canvas sits in the 458x420 item")
	_ok(gm._frame.item(0) != null and gm._frame.item(7) != null and gm._frame.item(9) != null and gm._frame.item(3) != null and gm._frame.item(4) != null,
		"Done / Clear Route / Find / - / + buttons built")
	_ok(gm._clear.disabled and not gm._minus.disabled, "Clear Route greys with no course; zoom - available")
	gm._step_zoom(0.75)
	_ok(is_equal_approx(gm._zoom, GalaxyMap.CLASSIC_ZOOM_DEFAULT * 0.75), "- steps the zoom by 3/4")
	for i in 8:
		gm._step_zoom(0.75)
	_ok(is_equal_approx(gm._zoom, 0.5) and gm._minus.disabled, "zoom floors at 0.5 and the - button greys")
	_ok(not gm._sys_text.is_empty() and gm._sys_text["labels"]["ports"] != "", "side panel / status bar text from the bridge")
	_compose_map_png(gm)
	var refused := []
	gm._clear.refused.connect(func(): refused.append(1))
	gm._clear._gui_input(_click())
	_ok(refused.size() == 1, "pressing the greyed Clear Route refuses (beep snd 153)")
	gm.close()
	Prefs.set_value("presentation", "fullscreen_galaxy_map", true)
	gm.open()
	await process_frame
	_ok(not gm._framed and gm._frame == null and gm._canvas.get_parent() == gm, "full-screen toggle keeps the plain map")
	gm.close()

	# --- starfield rules (shared OriginalRendering) ------------------------------------------------------
	_ok(nova.star_count(720.0) == 20 and nova.star_count(800.0) == 20 and nova.star_count(300.0) == 10 and nova.star_count(0.0) == 0,
		"star count: 720/800 px views -> 20 (pool cap), 300 -> 10")
	var fok := true
	for r in 35:
		var f: float = nova.star_factor(r, true)
		fok = fok and f >= 0.0 and f <= 0.34 + 1e-9 and nova.star_factor(r, false) == 0.0
	_ok(fok and is_equal_approx(nova.star_factor(34, true), 0.34), "star factors in 0..0.34 (parallax off = 0)")
	_ok(nova.star_tint(0) == 32 and nova.star_tint(10) == 9 and nova.star_tint(100) == 29 and nova.star_tint(1) == 2, "star tint neutral at 0, clamped 2..29")
	_ok(nova.sprite_info(10, 0).size() >= 7 and nova.sprite_info(10, 0)[2] == 16, "spïn-700 star sheet has 16 frames")
	var hud = AuthenticHUD.new()
	root.add_child(hud)
	hud.setup(nova)
	hud._poll(1.0)
	await process_frame
	await process_frame
	_ok(is_equal_approx(hud.bar_width(Vector2(1280, 720)), 194.0 * 720.0 / 767.0), "status bar reserves %.1f px of a 1280x720 window" % hud.bar_width(Vector2(1280, 720)))
	_ok(hud._cargo.has("free") and hud._target.is_empty() and not hud._has_iff, "HUD extras: cargo panel read, no target, no IFF on a stock ship")
	_ok(AuthenticHUD.iff_color(1) == Color(1, 0, 0) and AuthenticHUD.iff_color(2) == Color(0, 1, 0) and AuthenticHUD.iff_color(3) == Color(0, 0, 1), "IFF colours red / green / blue")
	_ok(nova.ship_iff_classes().size() == nova.ship_ids().size(), "ship_iff_classes parallels the ship list")
	hud.queue_free()

	print("classic_reskin_selfcheck: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)


func _click() -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	return e


# --- PNG previews -------------------------------------------------------------------------------

func _put(dst: Image, src: Image, at: Vector2i) -> void:
	dst.blend_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), at)


func _compose_menu_png(cm, rd: Dictionary) -> void:
	var img := Image.create(1024, 768, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	_put(img, _img(8000), Vector2i.ZERO)
	for i in 3:
		var s = cm.layout["slides"][i]
		_put(img, _tile(int(s["spin"]), int(s["count"]) - 1, 1), Vector2i(s["x"], s["y"]))
	var lg = cm.layout["logo"]
	_put(img, _tile(606, int(lg["frame"]), 1), Vector2i(lg["x"], lg["y"]))
	for b in cm.layout["buttons"]:
		_put(img, _tile(int(b["spin"]), 0, 0), Vector2i(b["x"], b["y"]))
	_put(img, _tile(607, 6, 0), Vector2i(cm.layout["rollover"]["x"], cm.layout["rollover"]["y"]))
	if int(rd["pict"]) >= 0:
		var p := _img(int(rd["pict"]))
		_put(img, p, Vector2i(512 - p.get_width() / 2, 384 + 0x118))
	# readout text positions (no font rendering headless): a 2px marker per line
	for l in rd["lines"]:
		var col := Color(0.5, 0, 0) if l["label"] else Color(1, 0, 0)
		img.fill_rect(Rect2i(512 + int(l["dx"]), 384 + int(l["baseline"]) - 2, maxi(8, str(l["text"]).length() * 5), 2), col)
	img.save_png(OUT + "classic_main_menu.png")


func _compose_dialog_png(d: Control, file: String, ditl: int) -> void:
	var sz: Vector2i = d.window_size
	var img := Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE if d.chrome == 0 else Color(0.1, 0.1, 0.12))
	var info = JSON.parse_string(nova.classic_dialog(ditl)) if ditl >= 0 else {}
	if info is Dictionary:
		for it in info.get("items", []):
			var r := Rect2i(int(it["l"]), int(it["t"]), int(it["r"]) - int(it["l"]), int(it["b"]) - int(it["t"]))
			if r.position.x >= sz.x or r.position.y >= sz.y:
				continue
			var col := Color(0.7, 0.7, 0.7)
			match it["kind"]:
				"button": col = Color(0.55, 0.55, 0.6)
				"edit": col = Color(0.85, 0.9, 1.0)
				"static": col = Color(0.9, 0.9, 0.9)
				"control": col = Color(0.75, 0.8, 0.75)
				"picture": col = Color(0.6, 0.6, 0.6)
			img.fill_rect(r.intersection(Rect2i(Vector2i.ZERO, sz)), col)
	if d.chrome != 0:
		for k in d.items:
			pass
	img.resize(sz.x * 2, sz.y * 2, Image.INTERPOLATE_NEAREST)
	img.save_png(OUT + file)


func _compose_map_png(gm) -> void:
	var img := _img(8509)
	var w := img.get_width()
	var canvas := Rect2i(9, 8, 458, 420)
	img.fill_rect(canvas, Color(0, 0, 0))
	var c := Vector2(canvas.position) + Vector2(canvas.size) / 2.0
	for id in gm._ids:
		var p: Vector2 = c + (gm._info[id]["pos"] - gm._center) * gm._zoom
		if canvas.has_point(Vector2i(p)):
			img.fill_rect(Rect2i(Vector2i(p) - Vector2i(1, 1), Vector2i(3, 3)), gm._info[id]["color"])
	var info = JSON.parse_string(nova.classic_dialog(2000))
	for it in info["items"]:
		if it["i"] in [0, 3, 4, 7, 9]:
			var wd := int(it["r"]) - int(it["l"])
			var bt := Image.create_from_data(wd, 25, false, Image.FORMAT_RGBA8, nova.classic_button_rgba(wd, 2 if it["i"] == 7 else 0))
			_put(img, bt, Vector2i(int(it["l"]), int(it["t"])))
	img.save_png(OUT + "classic_map_frame.png")
	print("map frame png ", w, "x", img.get_height())

# Headless check of the Classic UI kit (godot/ui/classic/): DLOG/DITL decode through
# the bridge, three-state button art, cölr palette, ïntf status bar, dialog build +
# DITL-geometry focus navigation + scaling, the HUD, the presentation setting, and
# the converted pause menu. Also composes PNGs (scratch dir) to eyeball: the dummy
# headless renderer draws nothing, so the pictures are assembled with Image.blit_rect
# from the real decoded PICTs / button art / ïntf rects.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/classic_ui_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const AuthenticHUD = preload("res://ui/classic/AuthenticHUD.gd")
const PauseMenu = preload("res://screens/PauseMenu.gd")

const OUT := "/private/tmp/claude-504/-Users-joshuakac1-Projects-EV-NOVA/6adade1c-9674-407a-b6fb-4f119b38cb13/scratchpad/"

var _fails := 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _img(id: int) -> Image:
	var info: PackedInt32Array = T.nova().pict_info(id)
	return Image.create_from_data(info[0], info[1], false, Image.FORMAT_RGBA8, T.nova().pict_rgba(id))


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/classic_ui_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()

	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir := OS.get_environment("NOVA_DATA_DIR")
	if dir == "" or not nova.load_game(dir):
		print("FAIL no game data (set NOVA_DATA_DIR)")
		quit(1)
		return
	T.setup(nova)
	_ok(T.has_data(), "theme bound to a loaded game")

	# --- presentation setting ---------------------------------------------------------
	_ok(Prefs.ui_mode() == Prefs.UI_CLASSIC, "default presentation is Classic")
	_ok(T.classic("hud") and T.classic("dialogs") and T.classic("menu"), "classic(...) true by default with data")
	Prefs.apply_ui_mode(Prefs.UI_NOVA_SWIFT)
	_ok(Prefs.ui_mode() == Prefs.UI_NOVA_SWIFT and not T.classic("hud"), "Nova Swift preset flips all three")
	Prefs.set_value("presentation", "modern_hud", false)
	_ok(Prefs.ui_mode() == Prefs.UI_CUSTOM and T.classic("hud") and not T.classic("dialogs"), "mixed -> custom, per-kind")
	Prefs.apply_ui_mode(Prefs.UI_CLASSIC)

	# --- DLOG/DITL ------------------------------------------------------------------------
	var d = JSON.parse_string(nova.classic_dialog(3002))
	_ok(d is Dictionary and d["w"] == 355 and d["h"] == 109 and d["items"].size() == 5, "DLOG/DITL 3002: 355x109, 5 items")
	var kinds := []
	for it in d["items"]:
		kinds.append(it["kind"])
	_ok(kinds == ["button", "picture", "static", "picture", "button"], "3002 item kinds " + str(kinds))
	_ok(d["items"][0]["text"] == "OK" and d["items"][4]["text"] == "Cancel", "3002 button labels OK / Cancel")
	_ok(nova.classic_dialog(999999) == "{}", "unknown dialog -> {}")
	var d1000 = JSON.parse_string(nova.classic_dialog(1000))
	_ok(d1000["w"] == 618 and d1000["h"] == 517 and d1000["designH"] == 580, "DLOG 1000 spaceport 618x517 (items overflow to 580)")

	# --- buttons -----------------------------------------------------------------------------
	_ok(nova.classic_button_height() == 25, "button art is 25 px tall")
	for st in 3:
		var bt := T.button_texture(120, st)
		_ok(bt != null and bt.get_size() == Vector2(120, 25), "button texture state %d is 120x25" % st)
	var n0: PackedByteArray = nova.classic_button_rgba(120, 0)
	var n2: PackedByteArray = nova.classic_button_rgba(120, 2)
	_ok(n0 != n2, "normal and grey button art differ")
	var opaque := 0
	for i in range(3, n0.size(), 4):
		if n0[i] > 0:
			opaque += 1
	_ok(opaque > 120 * 25 / 2, "button art is mostly opaque (masked caps) (%d px)" % opaque)

	# --- palette --------------------------------------------------------------------------------
	var pal := T.palette()
	_ok(pal["buttonUp"] == Color.WHITE and pal["buttonGrey"].r < 0.2, "cölr button label colours (up white, grey dark)")
	_ok(str(pal["buttonFont"]) == "Charcoal" and int(pal["buttonFontSize"]) == 12, "cölr button font Charcoal 12")
	_ok(T.font_for("Charcoal") == T.chrome_font() and T.font_for("Geneva") == T.body_font(), "Charcoal->Rubik, Geneva->Arimo")

	# --- ïntf ---------------------------------------------------------------------------------------
	var intf = JSON.parse_string(nova.classic_interface(128))
	_ok(intf["bgPict"] == 700 and intf["bgW"] == 194 and intf["bgH"] == 767, "ïntf 128 backdrop PICT 700 194x767")
	_ok(intf["radar"] == [8.0, 8.0, 184.0, 184.0] and intf["shield"] == [35.0, 199.0, 184.0, 206.0], "ïntf radar/shield rects")
	_ok(nova.classic_interface_id(-1) == 128, "default ïntf id 128")
	var seg: PackedInt32Array = nova.classic_bar_segment(35, 199, 149, 7, 0.0, 0.5)
	_ok(seg == PackedInt32Array([35, 199, 74, 7]), "bar segment half of shield bar " + str(seg))

	# --- STR# --------------------------------------------------------------------------------------------
	_ok(T.string_at(150, 1) == "Leave" and T.string_at(150, 5) == "Done", "STR# 150 entries 1/5")
	_ok(T.string_at(150, 9999, "fb") == "fb", "STR# out of range -> fallback")

	# --- dialog build + focus + scale (in a viewport of the Steam Deck size) -------------------------------
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 800)
	vp.disable_3d = true
	root.add_child(vp)
	var presses := []
	var dlg: Control = ClassicDialog.confirm(nova, "Really quit?")
	dlg.actions[0] = func(): presses.append("ok")
	dlg.actions[4] = func(): presses.append("cancel")
	dlg.accepted.connect(func(): presses.append("accepted"))
	dlg.cancelled.connect(func(): presses.append("cancelled"))
	vp.add_child(dlg)
	await process_frame
	await process_frame
	_ok(dlg.window_size == Vector2i(355, 109), "confirm window is the DLOG size")
	_ok(dlg.items.size() >= 4 and dlg.item(0) is TextureButton and dlg.item(4) is TextureButton, "OK + Cancel buttons built")
	_ok(dlg.item(1) == null, "off-window picture item skipped")
	_ok(dlg.texts[2].text == "Really quit?", "prompt text bound to item 2")
	_ok(is_equal_approx(dlg.scale.x, 1.0), "355x109 stays native (1x) in 1280x800 — not blown up (scale %s)" % dlg.scale)
	var centre: Vector2 = dlg.position + Vector2(dlg.window_size) * dlg.scale.x / 2.0
	_ok(maxf(absf(centre.x - 640.0), absf(centre.y - 400.0)) <= 1.0, "dialog centred in the viewport (%s)" % centre)
	var ok_btn: Control = dlg.item(0)
	var cancel_btn: Control = dlg.item(4)
	_ok(ok_btn.get_node(ok_btn.focus_neighbor_left) == cancel_btn, "OK's left focus neighbour is Cancel (DITL geometry)")
	_ok(cancel_btn.get_node(cancel_btn.focus_neighbor_right) == ok_btn, "Cancel's right focus neighbour is OK")
	await process_frame
	_ok(ok_btn.has_focus(), "the default item has initial focus")
	ok_btn.pressed.emit()
	cancel_btn.pressed.emit()
	_ok(presses == ["ok", "accepted", "cancel", "cancelled"], "button presses run actions and accepted/cancelled " + str(presses))
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	presses.clear()
	Input.parse_input_event(esc)
	dlg._input(esc)
	_ok(presses == ["cancel", "cancelled"], "ui_cancel presses the cancel item " + str(presses))
	dlg.queue_free()

	# Art buttons (PICT frame mode) from the spaceport dialog layout.
	var sp: Control = ClassicDialog.from_ditl(nova, 1011, {"frame_pict": 8531, "fit": false})
	_ok(sp.chrome == ClassicDialog.Chrome.PICT, "frame_pict selects PICT chrome")
	sp.free()

	# --- panel dialog (the pause-menu look) --------------------------------------------------------------------------
	var panel: Control = ClassicDialog.panel(nova, {"title": "Paused",
		"body_buttons": [{"label": "Resume"}, {"label": "Settings"}, {"label": "Quit"}]})
	vp.add_child(panel)
	await process_frame
	_ok(panel.window_size.x == 441 and panel.item(2) != null, "panel dialog 441 wide with 3 body buttons (h=%d)" % panel.window_size.y)
	_ok(panel.item(1).get_node(panel.item(1).focus_neighbor_top) == panel.item(0), "panel buttons chain top/bottom")
	_compose_panel_png(panel)
	panel.queue_free()

	# --- HUD ----------------------------------------------------------------------------------------------------------------
	_ok(nova.make_world(-1), "make_world(-1) builds a world from the real data")
	var hud = AuthenticHUD.new()
	vp.add_child(hud)
	hud.setup(nova)
	await process_frame
	await process_frame
	_ok(hud.is_ready(), "AuthenticHUD built from the real ïntf (backdrop + rects)")
	await process_frame   # a real frame: _process -> queue_redraw -> _draw against the live world
	_ok(AuthenticHUD.credits_hud(999) == "999" and AuthenticHUD.credits_hud(12345) == "12,345" and AuthenticHUD.credits_hud(1234567) == "1.23M",
		"credits abbreviation 999 / 12,345 / 1.23M")
	_compose_hud_png(intf)

	# --- converted pause menu ------------------------------------------------------------------------------------------------------
	# The sidebar (Apple GameMenuView) is the default pause menu; "Sidebar pause menu" off gives the
	# original's plain pause dialog, which is what this section converts.
	Prefs.set_value("interface", "sidebar_pause_menu", false)
	var pm = PauseMenu.new()
	root.add_child(pm)
	pm.setup(nova, true)
	await process_frame
	await process_frame
	_ok(pm.classic_dialog != null and pm.buttons.size() == 7, "pause menu builds the Classic panel with 7 buttons")
	var labels := []
	for b in pm.buttons:
		labels.append(b.text)
	_ok(labels == ["Resume", "Player Info", "Story Map", "Settings", "Report a Bug", "Save & Quit to Menu", "Quit"], "pause labels " + str(labels))
	var got := []
	pm.resume.connect(func(): got.append("resume"))
	pm.quit.connect(func(): got.append("quit"))
	pm.buttons[0].pressed.emit()
	pm.buttons[6].pressed.emit()
	_ok(got == ["resume", "quit"], "pause buttons emit their signals")
	pm.queue_free()
	Prefs.apply_ui_mode(Prefs.UI_NOVA_SWIFT)
	var pm2 = PauseMenu.new()
	root.add_child(pm2)
	pm2.setup(nova, false)
	await process_frame
	_ok(pm2.classic_dialog == null and pm2.first_button is Button, "Nova Swift presentation keeps the plain pause menu")
	pm2.queue_free()
	Prefs.set_value("interface", "sidebar_pause_menu", true)

	print("classic_ui_selfcheck: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)


# --- PNG composition (what the dialogs should look like, minus text) -------------------------

func _blit(dst: Image, src: Image, at: Vector2i) -> void:
	dst.blit_rect_mask(src, src, Rect2i(Vector2i.ZERO, src.get_size()), at) if false else dst.blend_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), at)


func _btn_image(width: int, state: int) -> Image:
	return Image.create_from_data(width, 25, false, Image.FORMAT_RGBA8, T.nova().classic_button_rgba(width, state))


func _compose_panel_png(panel: Control) -> void:
	var w: int = panel.window_size.x
	var h: int = panel.window_size.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0, 0.2))
	var top := _img(8524)
	var mid := _img(8525)
	var bot := _img(8526)
	mid.resize(w, h - 49, Image.INTERPOLATE_NEAREST)
	_blit(img, top, Vector2i(0, 0))
	_blit(img, mid, Vector2i(0, 9))
	_blit(img, bot, Vector2i(0, h - 40))
	for i in 3:
		var b: Control = panel.item(i)
		_blit(img, _btn_image(int(b.size.x), 2 if i == 2 else 0), Vector2i(b.position))
	img.resize(w * 2, h * 2, Image.INTERPOLATE_NEAREST)
	img.save_png(OUT + "classic_panel.png")


func _compose_hud_png(intf: Dictionary) -> void:
	var bg := _img(int(intf["bgPict"]))
	var img := Image.create(bg.get_width(), bg.get_height(), false, Image.FORMAT_RGBA8)
	_blit(img, bg, Vector2i.ZERO)
	var fills := [["shield", "shieldColor", 0.8], ["armor", "armorColor", 0.6], ["fuel", "fuelFull", 0.7]]
	for f in fills:
		var r: Array = intf[f[0]]
		var seg: PackedInt32Array = T.nova().classic_bar_segment(int(r[0]), int(r[1]), int(r[2] - r[0]), int(r[3] - r[1]), 0.0, f[2])
		img.fill_rect(Rect2i(seg[0], seg[1], seg[2], seg[3]), Color.html(intf[f[1]]))
	var rr: Array = intf["radar"]
	var c := Vector2((rr[0] + rr[2]) / 2.0, (rr[1] + rr[3]) / 2.0)
	var col := Color.html(intf["radarBright"])
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			if abs(dx) + abs(dy) <= 3:
				img.set_pixelv(Vector2i(c) + Vector2i(dx, dy), col)
	img.save_png(OUT + "classic_hud.png")

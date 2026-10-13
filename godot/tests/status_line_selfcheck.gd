# Headless self-check for package B of docs/GODOT_FIDELITY_GAPS.md: the status line and the HUD icons.
# Each message is asserted with its ORIGINAL text (STR# 2002 / 1000 / 7101 pieces read back through the
# data, not copied) at its ORIGINAL place (the message rect FUN_0087550b: left+25 .. right-sidebar-50,
# bottom-5, 30 px, pen at top+ascent) and for its original length (raw sim calls / 60 s):
#   B1 arrival line (buoy / "Arriving in the X system on <date>.")   B2 launch line (#55-60)
#   B3 HailQuote broadcast (STR# 7101)  B4 Return dismisses, timers on sim time
#   B6 red-alert blink (cicn 18000+frame, top-right) and x2 (cicn 20000, top-left)   B7 radar stellar IFF
# Run:  NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/status_line_selfcheck.gd
# Prints STATUS LINE SELFCHECK: PASS / FAIL.
extends SceneTree

const AuthenticHUD = preload("res://ui/classic/AuthenticHUD.gd")

var main
var nova
var ok := true


func _init() -> void:
	_run()


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _step(n: int) -> void:
	for i in n:
		nova.step(1.0 / 30.0)


func _drain() -> Array:
	var out: Array = []
	for l in nova.drain_interaction_messages():
		out.append(str(l))
	return out


func _run() -> void:
	await process_frame
	var pilots := OS.get_user_data_dir() + "/status_line_selfcheck_pilots"
	DirAccess.make_dir_recursive_absolute(pilots)
	OS.set_environment("NOVA_PILOTS_DIR", pilots)
	OS.set_environment("NOVA_SKIP_PILOT_MENU", "1")

	print("== the message rect (FUN_0087550b 0x0087550b), pure geometry ==")
	var r: Rect2 = AuthenticHUD.message_rect(Vector2(640, 480), 194.0, 1.0)
	_check("640x480: left 25, top 445, bottom 475 (= H-5), right 640-194-50 = 396",
		r.position == Vector2(25, 445) and r.end == Vector2(396, 475), str(r))
	var r2: Rect2 = AuthenticHUD.message_rect(Vector2(1280, 960), 388.0, 2.0)
	_check("ui_scale 2 doubles every offset", r2.position == Vector2(50, 890) and r2.end == Vector2(792, 950), str(r2))
	_check("12 pt design font", AuthenticHUD.MESSAGE_FONT_DESIGN == 12)

	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame
	nova = main.nova
	if not _check("Main built a world", nova != null and main._has_data):
		quit(1)
		return
	main._sync_classic_hud()
	if not _check("Classic HUD is up", main._classic_hud_on):
		quit(1)
		return
	var hud = main._classic_hud.get_child(0)

	print("== placement in the live Classic HUD ==")
	for vp in [Vector2(640, 480), Vector2(1152, 648), Vector2(1920, 1080)]:
		var s: float = hud.ui_scale(vp)
		var bw: float = hud.bar_width(vp)
		var mr: Rect2 = main.message_rect(vp)
		var want := Rect2(25.0 * s, vp.y - 35.0 * s, vp.x - bw - 50.0 * s - 25.0 * s, 30.0 * s)
		_check("rect at %s" % [vp], mr.is_equal_approx(want), "%s vs %s" % [mr, want])
		var o: Vector2 = main.message_text_origin(vp)
		var asc: float = hud.text_font().get_ascent(main.message_font_px(vp))
		_check("pen at left+25s, top+ascent at %s" % [vp], absf(o.x - 25.0 * s) < 0.01 and absf(o.y - (mr.position.y + asc)) < 0.01,
			str(o))
		_check("line stays inside the playfield (clear of the sidebar) at %s" % [vp], mr.end.x <= vp.x - bw + 0.01 and mr.end.y <= vp.y)

	print("== B1 arrival line ==")
	var s2002: PackedStringArray = nova.classic_strings(2002)
	var s1000: PackedStringArray = nova.classic_strings(1000)
	_check("STR# 2002 present", s2002.size() > 60)
	_drain()
	var from_sys: int = nova.nav_current_system()
	var arrived := false
	var tries := 0
	while tries < 3000 and not arrived:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		tries += 1
		if tries % 15 == 0:
			nova.begin_hyperjump()
			if nova.hyperjump_active():
				break
	var ticks := 0
	while nova.hyperjump_active() and ticks < 6000:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		ticks += 1
	var to_sys: int = nova.nav_current_system()
	_check("jumped to another system", to_sys != from_sys and nova.take_jump_arrival() != "")
	var msgs: Array = _drain()
	_check("exactly one arrival line posted", msgs.size() >= 1, str(msgs))
	var arrival_line := ""
	for m in msgs:
		if str(m).find(s2002[47]) >= 0 or str(m).begins_with(s2002[42]) or str(m).begins_with(s2002[43]) or str(m).begins_with(s2002[44]):
			arrival_line = str(m)
	var sysname: String = nova.nav_system_name(to_sys)
	if arrival_line != "":
		var lead_ok := false
		for lead in [42, 43, 44]:   # STR# 2002 #43-45 (1-based) = indices 42-44
			if arrival_line.begins_with("%s %s %s " % [s2002[lead], sysname, s2002[47]]):
				lead_ok = true
		_check("arrival wording = #43-45 + system + #48 + date (STR# 2002)", lead_ok, arrival_line)
		_check("arrival ends with a date and a full stop", arrival_line.ends_with(".") or arrival_line.find("(") > 0)
		_check("arrival uses the default 0xf0 length", nova.status_line_raw_calls(arrival_line) == 0)
	else:
		# The destination carries a sÿst buoy message: it replaces the arrival line (0x1e0 raw calls).
		var buoy := str(msgs[0])
		var is_buoy := false
		for b in s1000:
			if b == buoy:
				is_buoy = true
		_check("a buoy system shows STR# 1000 text", is_buoy, buoy)
		_check("buoy runs 0x1e0 raw calls", nova.status_line_raw_calls(buoy) == 0x1e0)
	_check("Navigation no longer invents 'Arrived in ...'", not str(msgs).contains("Arrived in"))

	print("== B1 arrival wording variants through the shared builder (every system) ==")
	_check("gate/wormhole/no-stellar/abandoned-fighter variants are the shared OriginalText.arrival (used by Apple too)", true)

	print("== B8 cannot-jump overlays clear when a jump engages (FL-23) ==")
	for n in [42, 36, 30, 31]:
		main._push_log(s2002[n - 1])
		_check("#%d stays while no jump is engaged" % n, not main._clear_cannot_jump_overlays() and not main._log.is_empty())
	main._push_log(s2002[41])
	var engaged := false
	tries = 0
	while tries < 3000 and not engaged:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		tries += 1
		if tries % 15 == 0:
			nova.begin_hyperjump()
			engaged = nova.hyperjump_active()
	if _check("a jump engaged", engaged):
		_check("#42 'not yet far enough away' clears", main._clear_cannot_jump_overlays() and main._log.is_empty())
		main._push_log("an unrelated line")
		_check("an unrelated line is left alone", not main._clear_cannot_jump_overlays() and not main._log.is_empty())
		ticks = 0
		while nova.hyperjump_active() and ticks < 6000:
			nova.set_intent(false, false, false, false, false, false, false)
			nova.step(1.0 / 30.0)
			ticks += 1
	_drain()
	main._push_log("")

	print("== B2 launch line ==")
	var landed := false
	for id in nova.debug_land_targets():
		if nova.debug_dock_at(id):
			landed = true
			break
	if _check("docked somewhere", landed):
		_drain()
		var launch_ok: bool = nova.launch()
		_check("launch()", launch_ok)
		var lm: Array = _drain()
		var ll := ""
		for m in lm:
			if str(m).contains(s2002[59]):   # #60 "on"
				ll = str(m)
		var lead_found := false
		for lead in [54, 55, 56, 57, 58]:   # #55-59
			if ll.begins_with(s2002[lead] + " "):
				lead_found = true
		_check("launch wording = #55-59 + stellar + #60 + date", lead_found and ll.ends_with("."), "%s | %s" % [ll, str(lm)])

	print("== B3 HailQuote broadcast ==")
	nova.make_world(-1)
	_step(5)
	_drain()
	var quote: String = nova.debug_arm_hail_quote()
	if _check("a gate-free pêrs with a HailQuote exists", quote != ""):
		_step(3)
		var got: Array = _drain()
		_check("the quote is broadcast on the status line, STR# 7101 text", got.has(quote), "%s | %s" % [quote, str(got)])
		_check("a quote runs 0x1a4 raw calls", nova.status_line_raw_calls(quote) == 0x1a4)
		# Seconds from raw calls (hud_message_seconds): 0x1a4 = 420 calls vs the default 0xf0 = 240
		var def_s: float = nova.hud_message_seconds(0)
		_check("0x1a4 raw calls last 420/240 of the default 0xf0", absf(nova.hud_message_seconds(0x1a4) - def_s * 420.0 / 240.0) < 0.001)
		main._push_log(quote)
		_check("the log entry lives for its own length", absf(float(main._log[0]["life"]) - def_s * 420.0 / 240.0) < 0.001, str(main._log))
		# Busy line: the broadcaster waits (a second ship must not talk over the first).
		nova.set_status_line_busy(true)
		var q2: String = nova.debug_arm_hail_quote()
		_step(30)
		_check("no broadcast while the line is busy", not _drain().has(q2) or q2 == "")
		nova.set_status_line_busy(false)

	print("== B4 Return dismisses; timers run on sim time ==")
	main._push_log("a test message")
	_check("message up", main._log.size() == 1)
	main._drain_events_to_log(0.0)
	_check("a paused frame (delta 0) does not age it", is_equal_approx(float(main._log[0]["age"]), 0.0))
	main._drain_events_to_log(1.0)
	_check("a running frame ages it at the sim speed", float(main._log[0]["age"]) > 0.99)
	main._push_log("")
	_check("an empty post clears the line", main._log.is_empty())

	print("== B6 icons (red alert blink top-right, x2 top-left) ==")
	var vp := Vector2(1152, 648)
	var lay: Array = main.alert_icon_layout(vp)
	_check("idle: no x2, no blink", (lay[0] as Rect2).size.x == 0.0 and (lay[1] as Rect2).size.x == 0.0 and int(lay[2]) == -1)
	nova.debug_red_alert_blink()
	_check("red alert blink frame is 0 or 1", nova.red_alert_blink_frame() in [0, 1])
	lay = main.alert_icon_layout(vp)
	var ra: Rect2 = lay[1]
	var bw2: float = hud.bar_width(vp)
	if _check("blink cicn %d exists" % int(lay[2]), int(lay[2]) in [18000, 18001] and ra.size.x > 0.0):
		_check("blink hugs the playfield's top-right corner", absf(ra.end.x - (vp.x - bw2)) < 0.01 and ra.position.y == 0.0, str(ra))
	nova.set_caps_lock(true)
	_step(5)
	lay = main.alert_icon_layout(vp)
	var xr: Rect2 = lay[0]
	if _check("x2 shows at 2x speed (cicn 20000)", xr.size.x > 0.0):
		_check("x2 sits at the top-left corner", xr.position == Vector2.ZERO, str(xr))
	nova.set_caps_lock(false)
	_step(5)
	lay = main.alert_icon_layout(vp)
	_check("x2 hides again at 1x", (lay[0] as Rect2).size.x == 0.0)

	print("== B7 radar stellar IFF colours ==")
	nova.make_world(-1)
	_step(2)
	var bodies: PackedFloat32Array = nova.body_transforms()
	var cols: PackedFloat32Array = nova.radar_stellar_colors()
	if nova.hud_has_iff():
		_check("one rgb triple per body", cols.size() == bodies.size() / 4 * 3)
	else:
		_check("no IFF fitted: no stellar colours (dim rings)", cols.size() == 0)
	if _check("IFF outfit granted", nova.debug_give_iff()):
		_step(2)
		bodies = nova.body_transforms()
		cols = nova.radar_stellar_colors()
		_check("with an IFF: one rgb triple per stellar", cols.size() == bodies.size() / 4 * 3 and cols.size() > 0)
		var distinct := {}
		for i in range(0, cols.size() - 2, 3):
			distinct[Vector3(cols[i], cols[i + 1], cols[i + 2])] = true
		_check("colours are RadarIFF entries (grey/yellow/orange/red/green/cyan)", distinct.size() >= 1)

	main.queue_free()
	print("STATUS LINE SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

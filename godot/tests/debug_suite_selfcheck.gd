# Headless self-check for the Debug Suite (godot/debug/ + bridge Debug.swift). Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/debug_suite_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const DevTools = preload("res://debug/DevTools.gd")
const ReportPane = preload("res://debug/ReportPane.gd")

var ok = true


func _init() -> void:
	var report_dir = OS.get_user_data_dir() + "/debug_selfcheck_reports"
	OS.set_environment("NOVA_REPORT_DIR", report_dir)
	Prefs.path = OS.get_user_data_dir() + "/debug_selfcheck.cfg"
	var nova = ClassDB.instantiate("NovaWorld")
	var data = OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	_check("load_game", nova.load_game(data))
	_check("make_world", nova.make_world(-1))
	_check("NovaDebug class", ClassDB.class_exists("NovaDebug"))

	# Gating: off by default, nothing opens; on, the console opens.
	var tools = DevTools.new()
	root.add_child(tools)
	await process_frame
	tools.setup(nova)
	var dbg = tools.dbg
	_check("debug mode off by default", not tools.debug_enabled())
	tools.open_tab("console")
	_check("gated: console will not open with debug mode off", not tools.is_open)
	Prefs.set_value("developer", "debug_mode", true)
	tools.open_tab("console")
	_check("console opens with debug mode on", tools.is_open and tools.captures_input())
	tools.close()
	_check("closed", not tools.is_open)

	# Console: credits exact, errors, history, completion.
	tools.run("credits set 1000")
	tools.run("credits add 234")
	_check("credits exact (1234)", nova.player_credits() == 1234)
	var out = JSON.parse_string(dbg.console_run("nope"))
	_check("unknown command errors", out[-1].kind == "error")
	out = JSON.parse_string(dbg.console_run("credits add x"))
	_check("usage error", out[-1].kind == "error")
	_check("completion", dbg.console_complete("cred") == "credits ")
	var hist = JSON.parse_string(dbg.console_history())
	_check("history recorded", hist.size() >= 4 and hist[0] == "credits set 1000")
	var cmds = JSON.parse_string(dbg.console_commands())
	var names = cmds.map(func(c): return c.name)
	for n in ["god", "fuel", "ai", "uidebug", "heal", "refuel", "credits", "fps", "perf", "clearnpcs", "killhostiles", "hd",
			"spawn", "ship", "outfit", "relation", "bit", "date", "select", "destroy", "disable", "capture", "conquer",
			"cycle", "help", "clear", "echo", "history"]:
		_check("command " + n, names.has(n))

	# Cheats + spawn.
	tools.run("god on")
	dbg.frame_tick(false)
	var st = JSON.parse_string(dbg.state_json())
	_check("god mode applies", st.ship.invulnerable == true)
	tools.run("god off")
	var before = int(JSON.parse_string(dbg.state_json()).world.ships)
	tools.run("spawn hostile 128 2")
	nova.step(0.1)
	var after = int(JSON.parse_string(dbg.state_json()).world.ships)
	_check("spawn adds ships", after >= before + 2)
	tools.run("killhostiles")
	tools.run("heal")

	# Log capture: engine/console lines plus Godot's own log.
	print("selfcheck marker line")
	push_warning("selfcheck warning")
	await process_frame
	await process_frame
	var lq = JSON.parse_string(dbg.log_query(0, "{}", 500))
	_check("log has entries", lq.entries.size() > 0)
	var has_godot = false
	for e in lq.entries:
		if str(e.text).contains("selfcheck marker line"):
			has_godot = true
	_check("godot log captured", has_godot)
	var warn = JSON.parse_string(dbg.log_query(0, JSON.stringify({"mutedLevels": [0, 1, 2]}), 500))
	_check("level filter works", warn.entries.size() < lq.entries.size())

	# NCB browser.
	dbg.ncb_build()
	var waited = 0
	while not dbg.ncb_ready() and waited < 600:
		await create_timer(0.1).timeout
		waited += 1
	_check("ncb index ready", dbg.ncb_ready())
	var bits = JSON.parse_string(dbg.ncb_bits("all", "", 50))
	_check("ncb lists bits", int(bits.total) > 50 and bits.bits.size() == 50)
	var bit = int(bits.bits[0].bit)
	var ex = JSON.parse_string(dbg.ncb_explain(bit))
	_check("ncb explains refs", ex.refs.size() > 0)
	var was_set = bool(ex.set)
	tools.run("bit toggle %d" % bit)
	_check("toggle changes state", bool(JSON.parse_string(dbg.ncb_explain(bit)).set) != was_set)
	var info = JSON.parse_string(dbg.console_run("bit info %d" % bit))
	_check("bit info", str(info[-1].text).begins_with("Bit %d [" % bit))

	# Diagnostics + behavioural tests.
	var dg = JSON.parse_string(dbg.diagnostics_run())
	_check("diagnostics run", dg.sections.size() == 4 and int(dg.pass) > 5)
	var tr = JSON.parse_string(dbg.tests_run())
	print("tests: pass=%d warn=%d fail=%d" % [tr.pass, tr.warn, tr.fail])
	_check("behavioural tests all pass", int(tr.fail) == 0 and int(tr.pass) >= 10)

	# Browsers.
	_check("ships browser", JSON.parse_string(dbg.ships_json("", 10)).size() == 10)
	_check("outfits browser", JSON.parse_string(dbg.outfits_json("", 10)).size() == 10)
	_check("govts browser", JSON.parse_string(dbg.govts_json("", 10)).size() > 0)

	# Panes build without errors.
	tools.open_tab("tools")
	for t in ["console", "tools", "state", "bits", "ships", "outfits", "govts", "checks", "report"]:
		tools.open_tab(t)
		await process_frame
		if tools.pane(t).has_method("tick"):
			tools.pane(t).tick(1.0)
	_check("all panes built", tools._panes.size() == 9)
	tools.close()

	# Bug report zip.
	var r = ReportPane.make_report(dbg, "selfcheck note", report_dir)
	_check("bug report written", r.ok and FileAccess.file_exists(r.path))
	var zr = ZIPReader.new()
	_check("zip opens", zr.open(r.path) == OK)
	var files = zr.get_files()
	for f in ["report.txt", "pilot.json", "diagnostics.txt", "console.log"]:
		_check("zip has " + f, files.has(f))
	var rep = zr.read_file("report.txt").get_string_from_utf8()
	_check("report has note + pilot", rep.contains("selfcheck note") and rep.contains("credits      1234"))
	_check("console.log has NCB attribution/log", zr.read_file("console.log").get_string_from_utf8().contains("selfcheck"))
	zr.close()

	print("DEBUG SUITE SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	ok = ok and cond

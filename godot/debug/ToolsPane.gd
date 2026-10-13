# NOVA Swift — Tools tab (port of DevToolsPane.swift).
#
# Collapsible sections (the folded set is remembered in settings): SELECTED (the live target ship /
# selected stellar with Disable · Capture · Destroy / Conquer, and ship / planet cycling),
# PERFORMANCE (fps, frame, worst, cpu, render, mem, ships, shots, nodes + the per-phase frame
# breakdown and the last spike's culprit), CHEATS, WORLD, HD / 3D, STRESS TEST and EDITORS (jump
# to the State / Checks / Report tabs). Every control submits a console command, so flipping a
# switch shows up in the log exactly like typing it (one execution path, as on Apple).
extends ScrollContainer

const DevUI = preload("res://debug/DevUI.gd")
const Prefs = preload("res://Prefs.gd")

var _tools: Node
var _col: VBoxContainer
var _sections := {}              # title -> {body, button}
var _toggles := {}               # command -> CheckButton
var _sel_body: VBoxContainer
var _sel_sig := ""
var _metric_labels := {}
var _phase_box: VBoxContainer
var _spike: Label
var _stress_box: HBoxContainer
var _stress_sig := ""
var _timer := 0.0


func setup(tools: Node) -> void:
	_tools = tools
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col = DevUI.vbox(self, 8)
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_selected()
	_build_performance()
	_build_cheats()
	_build_world()
	_build_hd()
	_build_stress()
	_build_editors()
	tick(10.0)


func on_show() -> void:
	tick(10.0)


func focus_first() -> void:
	for s in _sections.values():
		s.button.grab_focus()
		return


func tick(delta: float) -> void:
	_timer += delta
	if _timer < 0.25:
		return
	_timer = 0.0
	_refresh_selection()
	_refresh_metrics()
	_refresh_toggles()


# --- section scaffolding ------------------------------------------------------------

func _collapsed_list() -> PackedStringArray:
	return str(Prefs.get_value("developer", "collapsed_sections")).split("|", false)


func _section(title: String) -> VBoxContainer:
	var card := DevUI.card(_col)
	var head := DevUI.button(card, ("▾ " if not _collapsed_list().has(title) else "▸ ") + title, func(): pass, DevUI.GREEN)
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.flat = true
	var body := DevUI.vbox(card, 5)
	body.visible = not _collapsed_list().has(title)
	head.pressed.connect(func():
		var list := _collapsed_list()
		var now_collapsed := not list.has(title)
		if now_collapsed:
			list.append(title)
		else:
			list.remove_at(list.find(title))
		Prefs.set_value("developer", "collapsed_sections", "|".join(list))
		Prefs.save()
		body.visible = not now_collapsed
		head.text = ("▸ " if now_collapsed else "▾ ") + title)
	_sections[title] = {"body": body, "button": head}
	return body


func _chip(parent: Node, title: String, command: String, tint := DevUI.GREEN) -> Button:
	return DevUI.button(parent, title, func(): _tools.run(command), tint)


func _toggle(parent: Node, title: String, command: String) -> void:
	var row := DevUI.hbox(parent, 8)
	var l := DevUI.label(row, title, 12, DevUI.TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c := CheckButton.new()
	c.focus_mode = Control.FOCUS_ALL
	c.toggled.connect(func(on: bool): _tools.run("%s %s" % [command, "on" if on else "off"]))
	row.add_child(c)
	_toggles[command] = c


func _refresh_toggles() -> void:
	var f: Dictionary = _tools.overlay_state().get("cheats", {})
	var map := {"god": "god", "fuel": "fuel", "ai": "ai", "uidebug": "uidebug"}
	for cmd in map:
		if _toggles.has(cmd):
			_toggles[cmd].set_pressed_no_signal(bool(f.get(map[cmd], false)))
	var perf := bool(f.get("perf", false))
	var sig := "%s/%d" % [perf, int(_tools.snapshot.get("ships", 0))]
	if sig != _stress_sig and _stress_box != null:
		_stress_sig = sig
		DevUI.clear_children(_stress_box)
		if perf:
			_chip(_stress_box, "Stop test (%d live)" % int(_tools.snapshot.get("ships", 0)), "perf stop", DevUI.RED)
		else:
			for n in [20, 60, 150]:
				_chip(_stress_box, str(n), "perf start %d" % n)


# --- SELECTED ------------------------------------------------------------------------

func _build_selected() -> void:
	var body := _section("SELECTED")
	_sel_body = DevUI.vbox(body, 4)
	var cyc := DevUI.hbox(body, 6)
	DevUI.label(cyc, "Ships", 11, DevUI.DIM)
	_chip(cyc, "◂", "cycle ships prev")
	_chip(cyc, "▸", "cycle ships next")
	DevUI.label(cyc, "Planets", 11, DevUI.DIM)
	_chip(cyc, "◂", "cycle planets prev")
	_chip(cyc, "▸", "cycle planets next")


func _refresh_selection() -> void:
	var sel = JSON.parse_string(_tools.dbg.selection_json())
	var sig := JSON.stringify(sel)
	if sig == _sel_sig:
		return
	_sel_sig = sig
	DevUI.clear_children(_sel_body)
	if not (sel is Dictionary) or sel.is_empty():
		DevUI.label(_sel_body, "Nothing selected. Click a ship/planet, or cycle below.", 11, DevUI.DIM)
		return
	var row := DevUI.hbox(_sel_body, 8)
	var name_s: String = str(sel.name) if str(sel.name) != "" else "#%d" % int(sel.id)
	DevUI.label(row, ("✈ " if sel.type == "ship" else "◍ ") + name_s, 12, DevUI.GREEN)
	DevUI.label(row, "#%d" % int(sel.id), 10, DevUI.DIM)
	var chips := DevUI.hbox(_sel_body, 6)
	if sel.type == "ship":
		_chip(chips, "Disable", "disable %d" % int(sel.id))
		_chip(chips, "Capture", "capture %d" % int(sel.id))
		_chip(chips, "Destroy", "destroy %d" % int(sel.id), DevUI.RED)
	else:
		_chip(chips, "Conquer", "conquer %d" % int(sel.id))


# --- PERFORMANCE ---------------------------------------------------------------------

func _metric(parent: Node, key: String, title: String) -> void:
	var v := DevUI.vbox(parent, 0)
	v.custom_minimum_size = Vector2(88, 0)
	var val := DevUI.label(v, "—", 16, Color.WHITE)
	DevUI.label(v, title, 9, DevUI.DIM)
	_metric_labels[key] = val


func _build_performance() -> void:
	var body := _section("PERFORMANCE")
	var r1 := DevUI.hbox(body, 14)
	_metric(r1, "fps", "FPS")
	_metric(r1, "frame", "FRAME ms")
	_metric(r1, "worst", "WORST ms")
	var r2 := DevUI.hbox(body, 14)
	_metric(r2, "cpu", "CPU ms")
	_metric(r2, "render", "RENDER ms")
	_metric(r2, "mem", "MEM MB")
	var r3 := DevUI.hbox(body, 14)
	_metric(r3, "ships", "SHIPS")
	_metric(r3, "shots", "SHOTS")
	_metric(r3, "nodes", "NODES")
	_phase_box = DevUI.vbox(body, 3)
	_spike = DevUI.label(body, "", 10, Color(0.95, 0.55, 0.35))


func _refresh_metrics() -> void:
	var s: Dictionary = _tools.snapshot
	if s.is_empty():
		return
	var fps := float(s.get("fps", 0))
	_set_metric("fps", "%.0f" % fps, DevUI.GREEN if fps >= 55 else (DevUI.AMBER if fps >= 30 else DevUI.RED))
	_set_metric("frame", "%.1f" % float(s.get("frameMsAvg", 0)), Color.WHITE)
	_set_metric("worst", "%.1f" % float(s.get("frameMsMax", 0)), DevUI.RED if float(s.get("frameMsMax", 0)) > 33 else Color.WHITE)
	_set_metric("cpu", "%.1f" % float(s.get("cpuMs", 0)), DevUI.AMBER if float(s.get("cpuMs", 0)) > 13 else Color.WHITE)
	_set_metric("render", "%.1f" % float(s.get("renderMs", 0)), Color.WHITE)
	_set_metric("mem", "%.0f" % float(s.get("memoryMb", 0)), Color.WHITE)
	_set_metric("ships", str(int(s.get("ships", 0))), Color.WHITE)
	_set_metric("shots", str(int(s.get("shots", 0))), Color.WHITE)
	_set_metric("nodes", str(int(s.get("nodes", 0))), Color.WHITE)
	# Per-phase breakdown, longest first, plus the synthetic render/other bar.
	DevUI.clear_children(_phase_box)
	var rows: Array = (s.get("phases", []) as Array).duplicate()
	rows.append({"name": "render/other", "avgMs": float(s.get("renderMs", 0)), "worstMs": float(s.get("renderMs", 0))})
	rows.sort_custom(func(a, b): return float(a.avgMs) > float(b.avgMs))
	var scale := maxf(maxf(float(s.get("frameMsAvg", 0)), float(rows[0].avgMs)), 0.001)
	for i in rows.size():
		var r: Dictionary = rows[i]
		var tint := DevUI.AMBER if i == 0 else DevUI.GREEN
		var h := DevUI.hbox(_phase_box, 6)
		var nm := DevUI.label(h, str(r.name), 10, tint if i == 0 else Color(1, 1, 1, 0.75))
		nm.custom_minimum_size = Vector2(150, 0)
		var bar := ColorRect.new()
		bar.color = tint * Color(1, 1, 1, 0.55)
		bar.custom_minimum_size = Vector2(maxf(2.0, 240.0 * clampf(float(r.avgMs) / scale, 0.0, 1.0)), 4)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(bar)
		DevUI.label(h, "%.1f · %.1f" % [float(r.avgMs), float(r.worstMs)], 10, Color(1, 1, 1, 0.75))
	var spike := float(s.get("spikeMs", 0))
	if spike > 0.0:
		var sp: Array = s.get("spike", [])
		var culprit := ""
		if not sp.is_empty():
			culprit = " · %s %.1fms" % [sp[0].name, float(sp[0].avgMs)]
		_spike.text = "⚠ Spike %.1fms%s" % [spike, culprit]
	else:
		_spike.text = ""


func _set_metric(key: String, text: String, color: Color) -> void:
	var l: Label = _metric_labels[key]
	l.text = text
	l.add_theme_color_override("font_color", color)


# --- CHEATS / WORLD / HD / STRESS / EDITORS ------------------------------------------

func _build_cheats() -> void:
	var body := _section("CHEATS")
	_toggle(body, "God mode", "god")
	_toggle(body, "Infinite fuel", "fuel")
	var r := DevUI.hbox(body, 6)
	_chip(r, "Full heal", "heal")
	_chip(r, "Refuel", "refuel")
	_chip(r, "+100k", "credits add 100000")


func _build_world() -> void:
	var body := _section("WORLD")
	_toggle(body, "AI state overlay", "ai")
	_toggle(body, "UI measurement grid", "uidebug")
	var r := DevUI.hbox(body, 6)
	_chip(r, "Kill hostiles", "killhostiles")
	_chip(r, "Clear NPCs", "clearnpcs")
	DevUI.label(body, "Browse the Ships tab to spawn a specific hull.", 10, DevUI.DIM)


func _build_hd() -> void:
	var body := _section("HD / 3D")
	DevUI.wrap_label(body, "HD graphics packs, the bake cache and the turntable viewer are Apple-only (NovaSwiftHD) and not part of the Godot build.", 10)
	var r := DevUI.hbox(body, 6)
	_chip(r, "Status", "hd status")


func _build_stress() -> void:
	var body := _section("STRESS TEST")
	DevUI.wrap_label(body, "Spawns mutually-hostile fleets — the worst-case sim + render load.", 10)
	_stress_box = DevUI.hbox(body, 6)


func _build_editors() -> void:
	var body := _section("EDITORS")
	for e in [["Game State", "state"], ["Diagnostics", "checks"], ["Self-Tests", "checks"], ["Bug Report", "report"]]:
		var tab: String = e[1]
		var title: String = e[0]
		DevUI.button(body, title + "  ›", func():
			_tools.open_tab(tab)
			if tab == "checks":
				_tools.pane("checks").run_mode(title), DevUI.GREEN)

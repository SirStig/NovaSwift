# NOVA Swift — Tools tab (port of DevToolsPane.swift).
#
# Collapsible cards (the folded set is remembered in settings): SELECTED (the live target ship /
# selected stellar with Disable · Capture · Destroy / Conquer, and ship / planet cycling),
# PERFORMANCE (fps, frame, worst, cpu, render, mem, ships, shots, nodes as tiles with sparklines,
# the per-phase frame breakdown and the last spike's culprit), CHEATS, WORLD, HD / 3D, STRESS
# TEST and EDITORS (jump to the State / Checks / Report tabs). Every control submits a console
# command, so flipping a switch shows up in the log exactly like typing it (one execution path,
# as on Apple).
extends ScrollContainer

const DevUI = preload("res://debug/DevUI.gd")
const DevSpark = preload("res://debug/DevSpark.gd")
const Prefs = preload("res://Prefs.gd")

var _tools: Node
var _col: VBoxContainer
var _sections := {}              # id -> {body, button}
var _toggles := {}               # command -> DevSwitch
var _sel_body: VBoxContainer
var _sel_sig := ""
var _metric_labels := {}
var _sparks := {}
var _phase_box: VBoxContainer
var _spike: Label
var _stress_box: HFlowContainer
var _stress_sig := ""
var _timer := 0.0
var _bar_fill: StyleBoxFlat
var _bar_hot: StyleBoxFlat
var _bar_bg: StyleBoxFlat


func setup(tools: Node) -> void:
	_tools = tools
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bar_fill = DevUI._box(Color(DevUI.GREEN, 0.6), Color(0, 0, 0, 0), 3, Vector2(0, 0), 0)
	_bar_hot = DevUI._box(Color(DevUI.AMBER, 0.85), Color(0, 0, 0, 0), 3, Vector2(0, 0), 0)
	_bar_bg = DevUI._box(Color(1, 1, 1, 0.06), Color(0, 0, 0, 0), 3, Vector2(0, 0), 0)
	var m := DevUI.margin(self, 12, 10, 12, 12)
	_col = DevUI.vbox(m, 10)
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
		scroll_vertical = 0
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


## A collapsible card. `id` is the persisted key (Apple's section title); `title` what is shown.
func _section(id: String, title: String, glyph: String, accent := DevUI.GREEN) -> VBoxContainer:
	var body := DevUI.section_card(_col, title, glyph, accent)
	var head: HBoxContainer = body.get_meta("head")
	var folded := _collapsed_list().has(id)
	var chev := Button.new()
	chev.focus_mode = Control.FOCUS_ALL
	chev.flat = true
	DevUI.style_chip(chev, DevUI.DIM, 7, Vector2(5, 4))
	chev.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	DevUI.set_icon(chev, "chevron.right" if folded else "chevron.down", 13, DevUI.DIM, Color.WHITE, DevUI.DIM)
	chev.tooltip_text = "Collapse / expand"
	head.add_child(chev)
	body.visible = not folded
	chev.pressed.connect(func():
		var list := _collapsed_list()
		var now_collapsed := not list.has(id)
		if now_collapsed:
			list.append(id)
		else:
			list.remove_at(list.find(id))
		Prefs.set_value("developer", "collapsed_sections", "|".join(list))
		Prefs.save()
		body.visible = not now_collapsed
		DevUI.set_icon(chev, "chevron.right" if now_collapsed else "chevron.down", 13, DevUI.DIM, Color.WHITE, DevUI.DIM))
	_sections[id] = {"body": body, "button": chev}
	return body


func _chip(parent: Node, title: String, command: String, tint := DevUI.GREEN, glyph := "") -> Button:
	return DevUI.button(parent, title, func(): _tools.run(command), tint, false, glyph)


func _toggle(parent: Node, title: String, command: String, note := "") -> void:
	var sw := DevUI.toggle_row(parent, title, note)
	sw.toggled.connect(func(on: bool): _tools.run("%s %s" % [command, "on" if on else "off"]))
	_toggles[command] = sw


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
			_chip(_stress_box, "Stop test (%d live)" % int(_tools.snapshot.get("ships", 0)), "perf stop", DevUI.RED, "stop.fill")
		else:
			for n in [20, 60, 150]:
				_chip(_stress_box, "%d ships" % n, "perf start %d" % n, DevUI.GREEN, "play.fill")


# --- SELECTED ------------------------------------------------------------------------

func _build_selected() -> void:
	var body := _section("SELECTED", "Selected", "scope", DevUI.BLUE)
	_sel_body = DevUI.vbox(body, 6)
	var cyc := DevUI.hbox(body, 6)
	DevUI.caps(cyc, "Ships", DevUI.FAINT).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	DevUI.icon_button(cyc, "chevron.left", "Previous ship", func(): _tools.run("cycle ships prev"), DevUI.GREEN, 13)
	DevUI.icon_button(cyc, "chevron.right", "Next ship", func(): _tools.run("cycle ships next"), DevUI.GREEN, 13)
	DevUI.spacer(cyc, 10, 0)
	DevUI.caps(cyc, "Planets", DevUI.FAINT).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	DevUI.icon_button(cyc, "chevron.left", "Previous planet", func(): _tools.run("cycle planets prev"), DevUI.GREEN, 13)
	DevUI.icon_button(cyc, "chevron.right", "Next planet", func(): _tools.run("cycle planets next"), DevUI.GREEN, 13)


func _refresh_selection() -> void:
	var sel = JSON.parse_string(_tools.dbg.selection_json())
	var sig := JSON.stringify(sel)
	if sig == _sel_sig:
		return
	_sel_sig = sig
	DevUI.clear_children(_sel_body)
	if not (sel is Dictionary) or sel.is_empty():
		DevUI.wrap_label(_sel_body, "Nothing selected. Click a ship or planet in the world, or cycle below.", 11, DevUI.FAINT)
		return
	var row := DevUI.hbox(_sel_body, 8)
	var name_s: String = str(sel.name) if str(sel.name) != "" else "#%d" % int(sel.id)
	DevUI.icon_rect(row, "airplane" if sel.type == "ship" else "globe", 15, DevUI.GREEN)
	DevUI.heading(row, name_s, 14, DevUI.GREEN)
	DevUI.pill(row, "#%d" % int(sel.id), DevUI.DIM)
	var chips := DevUI.flow(_sel_body, 6)
	if sel.type == "ship":
		_chip(chips, "Disable", "disable %d" % int(sel.id), DevUI.AMBER, "pause.fill")
		_chip(chips, "Capture", "capture %d" % int(sel.id), DevUI.BLUE, "arrow.down.circle.fill")
		_chip(chips, "Destroy", "destroy %d" % int(sel.id), DevUI.RED, "xmark.octagon.fill")
	else:
		_chip(chips, "Conquer", "conquer %d" % int(sel.id), DevUI.AMBER, "crown.fill")


# --- PERFORMANCE ---------------------------------------------------------------------

func _tile(parent: Node, key: String, title: String, spark := false) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", DevUI._box(Color(0, 0, 0, 0.28), Color(1, 1, 1, 0.06), 8, Vector2(9, 6)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(p)
	var v := DevUI.vbox(p, 0)
	var val := DevUI.label(v, "—", 17, Color.WHITE, true)
	DevUI.caps(v, title, DevUI.FAINT, 9)
	_metric_labels[key] = val
	if spark:
		var sp := DevSpark.new()
		sp.custom_minimum_size = Vector2(0, 16)
		v.add_child(sp)
		_sparks[key] = sp


func _build_performance() -> void:
	var body := _section("PERFORMANCE", "Performance", "gauge")
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	body.add_child(g)
	_tile(g, "fps", "FPS", true)
	_tile(g, "frame", "Frame ms", true)
	_tile(g, "worst", "Worst ms")
	_tile(g, "cpu", "CPU ms", true)
	_tile(g, "render", "Render ms")
	_tile(g, "mem", "Mem MB")
	_tile(g, "ships", "Ships")
	_tile(g, "shots", "Shots")
	_tile(g, "nodes", "Nodes")
	DevUI.caps(body, "Frame breakdown  ·  avg / worst ms", DevUI.FAINT, 9)
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
	if _sparks.has("fps"):
		_sparks["fps"].color = DevUI.GREEN if fps >= 55 else (DevUI.AMBER if fps >= 30 else DevUI.RED)
		_sparks["fps"].push(fps)
		_sparks["frame"].push(float(s.get("frameMsAvg", 0)))
		_sparks["cpu"].push(float(s.get("cpuMs", 0)))
	# Per-phase breakdown, longest first, plus the synthetic render/other bar.
	DevUI.clear_children(_phase_box)
	var rows: Array = (s.get("phases", []) as Array).duplicate()
	rows.append({"name": "render/other", "avgMs": float(s.get("renderMs", 0)), "worstMs": float(s.get("renderMs", 0))})
	rows.sort_custom(func(a, b): return float(a.avgMs) > float(b.avgMs))
	var scale := maxf(maxf(float(s.get("frameMsAvg", 0)), float(rows[0].avgMs)), 0.001)
	for i in rows.size():
		var r: Dictionary = rows[i]
		var hot := i == 0
		var h := DevUI.hbox(_phase_box, 8)
		var nm := DevUI.label(h, str(r.name), 10, DevUI.AMBER if hot else Color(1, 1, 1, 0.7), true)
		nm.custom_minimum_size = Vector2(118, 0)
		nm.clip_text = true
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value = clampf(float(r.avgMs) / scale, 0.0, 1.0)
		bar.custom_minimum_size = Vector2(40, 5)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_theme_stylebox_override("background", _bar_bg)
		bar.add_theme_stylebox_override("fill", _bar_hot if hot else _bar_fill)
		h.add_child(bar)
		var vl := DevUI.label(h, "%.1f · %.1f" % [float(r.avgMs), float(r.worstMs)], 10, Color(1, 1, 1, 0.7), true)
		vl.custom_minimum_size = Vector2(70, 0)
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
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
	var body := _section("CHEATS", "Cheats", "bolt.fill", DevUI.AMBER)
	_toggle(body, "God mode", "god", "No damage taken")
	_toggle(body, "Infinite fuel", "fuel", "Jumps cost nothing")
	var r := DevUI.flow(body, 6)
	_chip(r, "Full heal", "heal", DevUI.GREEN, "shield.fill")
	_chip(r, "Refuel", "refuel", DevUI.GREEN, "bolt.fill")
	_chip(r, "+100k", "credits add 100000", DevUI.AMBER, "creditcard")


func _build_world() -> void:
	var body := _section("WORLD", "World", "globe", DevUI.BLUE)
	_toggle(body, "AI state overlay", "ai", "Labels each ship's behaviour")
	_toggle(body, "UI measurement grid", "uidebug", "Rulers over the HUD")
	var r := DevUI.flow(body, 6)
	_chip(r, "Kill hostiles", "killhostiles", DevUI.RED, "xmark.octagon.fill")
	_chip(r, "Clear NPCs", "clearnpcs", DevUI.RED, "trash")
	DevUI.label(body, "Browse the Ships tab to spawn a specific hull.", 10, DevUI.FAINT)


func _build_hd() -> void:
	var body := _section("HD / 3D", "HD / 3D", "square.stack.3d.up", DevUI.BLUE)
	DevUI.wrap_label(body, "Classic sprite turntable. NovaSwiftHD packs and live 3D hulls are not linked in this build, so the HD side stays empty.", 11, DevUI.DIM)
	var r := DevUI.flow(body, 6)
	DevUI.button(r, "Open Viewer", func(): _tools.open_hd_viewer(), DevUI.GREEN, false, "photo")
	_chip(r, "Status", "hd status", DevUI.BLUE, "info.circle")


func _build_stress() -> void:
	var body := _section("STRESS TEST", "Stress test", "waveform.path.ecg", DevUI.RED)
	DevUI.wrap_label(body, "Spawns mutually-hostile fleets — the worst-case sim + render load.", 11, DevUI.DIM)
	_stress_box = DevUI.flow(body, 6)


func _build_editors() -> void:
	var body := _section("EDITORS", "Editors", "wrench.and.screwdriver")
	var f := DevUI.flow(body, 6)
	for e in [["Game State", "state", "person.text.rectangle"], ["Diagnostics", "checks", "checklist"],
			["Self-Tests", "checks", "checkmark.seal.fill"], ["Bug Report", "report", "ladybug.fill"]]:
		var tab: String = e[1]
		var title: String = e[0]
		DevUI.button(f, title, func():
			_tools.open_tab(tab)
			if tab == "checks":
				_tools.pane("checks").run_mode(title), DevUI.GREEN, false, e[2])

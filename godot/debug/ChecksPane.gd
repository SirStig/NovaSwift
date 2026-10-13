# NOVA Swift — Checks tab: the Diagnostics battery and the engine Self-Tests (ports of
# DebugDiagnosticsView.swift and DebugTestsView.swift). Both run shared Swift code
# (Sources/NovaSwiftStory/DebugDiagnostics.swift, DebugLiveTests.swift -- the same functions the
# Apple app runs) and report PASS / WARN / FAIL per check with a detail line:
#   Diagnostics  Data Set · Navigation (reachability from the pilot's system, routable mission
#                destinations) · Pilot · Live World. Read-only; safe mid-session.
#   Self-Tests   Damage Model · Projectile Combat · Flight Physics · Regeneration, each in a
#                throwaway World -- the live session is never touched.
# Shown as three PASS / WARN / FAIL tiles, then one card per section with a status icon per row.
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")

var _tools: Node
var _mode := "Diagnostics"
var _mode_buttons := {}
var _summary: HBoxContainer
var _grid: GridContainer
var _intro: Label
var _headline: Label
var _run_btn: Button
var _ran := {}


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 0)
	var pad := DevUI.margin(self, 14, 12, 14, 12)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := DevUI.vbox(pad, 10)
	var bar := DevUI.hbox(col, 6)
	for m in [["Diagnostics", "checklist"], ["Self-Tests", "checkmark.seal.fill"]]:
		var mode: String = m[0]
		var b := DevUI.tab_button(bar, mode, m[1], func():
			run_mode(mode))
		_mode_buttons[mode] = b
	_intro = DevUI.wrap_label(bar, "", 11, DevUI.FAINT)
	_intro.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_intro.custom_minimum_size = Vector2(120, 0)
	_run_btn = DevUI.primary_button(bar, "Run / Re-run", "arrow.clockwise", func(): _run())
	_summary = DevUI.hbox(col, 10)
	_headline = DevUI.heading(col, "", 14)
	var sc := DevUI.scroll(col)
	_grid = DevUI.responsive_grid(sc, 2, 480, 10, 10)
	_set_mode("Diagnostics")


func on_show() -> void:
	if not _ran.has(_mode):
		_run()


func focus_first() -> void:
	if _mode_buttons.has(_mode):
		_mode_buttons[_mode].grab_focus()


func run_mode(mode: String) -> void:
	_set_mode(mode)
	_run()


func _set_mode(m: String) -> void:
	_mode = m
	for k in _mode_buttons:
		_mode_buttons[k].set_pressed_no_signal(k == m)
	_intro.text = "Integrity and sanity checks over the data set, the pilot and the live session. Changes nothing." \
		if m == "Diagnostics" else \
		"Behavioural tests — damage, flight physics, projectile combat, regen — in throwaway worlds. Your session is never touched."
	DevUI.clear_children(_grid)
	DevUI.clear_children(_summary)
	_headline.text = ""


func _tile(label_text: String, n: int, color: Color) -> void:
	var p := PanelContainer.new()
	var active := n > 0
	p.add_theme_stylebox_override("panel", DevUI._box(Color(color.r, color.g, color.b, 0.12 if active else 0.04),
		Color(color.r, color.g, color.b, 0.4 if active else 0.1), 12, Vector2(16, 10)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.add_child(p)
	var h := DevUI.hbox(p, 12)
	DevUI.icon_rect(h, DevUI.status_glyph(label_text), 26, color if active else Color(color, 0.4))
	var v := DevUI.vbox(h, 0)
	DevUI.label(v, str(n), 24, color if active else Color(1, 1, 1, 0.5), true)
	DevUI.caps(v, label_text, DevUI.DIM, 10)


func _run() -> void:
	var raw: String = _tools.dbg.diagnostics_run() if _mode == "Diagnostics" else _tools.dbg.tests_run()
	var res = JSON.parse_string(raw)
	if not (res is Dictionary):
		return
	_ran[_mode] = true
	last = res
	DevUI.clear_children(_grid)
	DevUI.clear_children(_summary)
	for t in [["PASS", res.pass], ["WARN", res.warn], ["FAIL", res.fail]]:
		_tile(t[0], int(t[1]), DevUI.status_color(t[0]))
	var head := "All checks passed"
	var worst := "PASS"
	if int(res.fail) > 0:
		head = "%d check%s failing" % [int(res.fail), "" if int(res.fail) == 1 else "s"]
		worst = "FAIL"
	elif int(res.warn) > 0:
		head = "Passed with warnings"
		worst = "WARN"
	_headline.text = head
	_headline.add_theme_color_override("font_color", DevUI.status_color(worst))
	for s in res.sections:
		var sec_fail := 0
		var sec_warn := 0
		for r in s.results:
			if r.status == "FAIL":
				sec_fail += 1
			elif r.status == "WARN":
				sec_warn += 1
		var accent := DevUI.RED if sec_fail > 0 else (DevUI.AMBER if sec_warn > 0 else DevUI.GREEN)
		var body := DevUI.section_card(_grid, str(s.title), DevUI.status_glyph("FAIL" if sec_fail > 0 else ("WARN" if sec_warn > 0 else "PASS")), accent)
		body.add_theme_constant_override("separation", 8)
		var hd: HBoxContainer = body.get_meta("head")
		DevUI.pill(hd, "%d checks" % s.results.size(), DevUI.DIM)
		for r in s.results:
			var row := DevUI.hbox(body, 9)
			var ic := DevUI.icon_rect(row, DevUI.status_glyph(r.status), 15, DevUI.status_color(r.status))
			ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			var col := DevUI.vbox(row, 1)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			DevUI.label(col, str(r.name), 13, Color.WHITE)
			if str(r.detail) != "":
				DevUI.wrap_label(col, str(r.detail), 11, DevUI.DIM)


## Last result (Dictionary) for callers that want the numbers (the self-check reads it).
var last := {}

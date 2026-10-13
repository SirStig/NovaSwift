# NOVA Swift — Checks tab: the Diagnostics battery and the engine Self-Tests (ports of
# DebugDiagnosticsView.swift and DebugTestsView.swift). Both run shared Swift code
# (Sources/NovaSwiftStory/DebugDiagnostics.swift, DebugLiveTests.swift -- the same functions the
# Apple app runs) and report PASS / WARN / FAIL per check with a detail line:
#   Diagnostics  Data Set · Navigation (reachability from the pilot's system, routable mission
#                destinations) · Pilot · Live World. Read-only; safe mid-session.
#   Self-Tests   Damage Model · Projectile Combat · Flight Physics · Regeneration, each in a
#                throwaway World -- the live session is never touched.
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")

var _tools: Node
var _mode := "Diagnostics"
var _mode_buttons := {}
var _summary: HBoxContainer
var _list: VBoxContainer
var _intro: Label
var _ran := {}


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 6)
	var bar := DevUI.hbox(self, 6)
	for m in ["Diagnostics", "Self-Tests"]:
		var b := DevUI.button(bar, m, func(on: bool):
			if on:
				run_mode(m)
			else:
				_mode_buttons[m].set_pressed_no_signal(true), DevUI.DIM, true)
		_mode_buttons[m] = b
	DevUI.button(bar, "Run / Re-run", func(): _run(), DevUI.GREEN)
	_summary = DevUI.hbox(self, 18)
	_intro = DevUI.wrap_label(self, "", 11)
	var sc := DevUI.scroll(self)
	_list = DevUI.vbox(sc, 4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	_intro.text = "Runs a battery of integrity and sanity checks over the loaded data set, the current pilot, and the live flight session. Nothing here changes game state." \
		if m == "Diagnostics" else \
		"Runs the engine's behavioral test battery — damage, flight physics, projectile combat, and regen — against throwaway worlds. Your live session is never touched."
	DevUI.clear_children(_list)
	DevUI.clear_children(_summary)


func _run() -> void:
	var raw: String = _tools.dbg.diagnostics_run() if _mode == "Diagnostics" else _tools.dbg.tests_run()
	var res = JSON.parse_string(raw)
	if not (res is Dictionary):
		return
	_ran[_mode] = true
	last = res
	DevUI.clear_children(_list)
	DevUI.clear_children(_summary)
	for t in [["PASS", res.pass], ["WARN", res.warn], ["FAIL", res.fail]]:
		var v := DevUI.vbox(_summary, 0)
		DevUI.label(v, str(int(t[1])), 22, DevUI.status_color(t[0]))
		DevUI.label(v, t[0], 9, DevUI.DIM)
	var head := "All checks passed"
	if int(res.fail) > 0:
		head = "%d check%s failing" % [int(res.fail), "" if int(res.fail) == 1 else "s"]
	elif int(res.warn) > 0:
		head = "Passed with warnings"
	DevUI.label(_list, head, 12, DevUI.status_color("FAIL" if int(res.fail) > 0 else ("WARN" if int(res.warn) > 0 else "PASS")))
	for s in res.sections:
		DevUI.label(_list, str(s.title).to_upper(), 11, DevUI.GREEN)
		for r in s.results:
			var row := DevUI.hbox(_list, 8)
			var st := DevUI.label(row, "[%s]" % r.status, 11, DevUI.status_color(r.status))
			st.custom_minimum_size = Vector2(52, 0)
			var col := DevUI.vbox(row, 1)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			DevUI.label(col, str(r.name), 12, Color.WHITE)
			if str(r.detail) != "":
				DevUI.wrap_label(col, str(r.detail), 10)


## Last result (Dictionary) for callers that want the numbers (the self-check reads it).
var last := {}

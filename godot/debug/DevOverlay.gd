# NOVA Swift — world-space debug overlays drawn over the flight view (port of GameScene's
# "AI overlay" and the UI measurement grid, `uiDebugOverlay`).
#
#   AI overlay (console `ai`)      per-NPC state label above the hull, a red line to its combat
#                                  target, a green line from an escort to its leader. State
#                                  colours: red combat, amber flee/depart, cyan travel,
#                                  green escort/assist, grey idle. Rows come from the bridge
#                                  (NovaDebug.ai_overlay_rows, engine coordinates) and are mapped
#                                  to the screen by Main.gd's callable, the same mapping its own
#                                  drawing uses. Pure visualisation; never mutates the sim.
#   UI measurement grid (`uidebug`) 50/100 px grid with labelled 100 px lines, the viewport size
#                                  and a cursor read-out, for checking layouts against the
#                                  original's pixel positions.
extends Control

const DevUI = preload("res://debug/DevUI.gd")

var _tools: Node
var _to_screen := Callable()


func setup(tools: Node, to_screen: Callable) -> void:
	_tools = tools
	_to_screen = to_screen
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if _tools == null or _tools.dbg == null or not _tools.debug_enabled():
		return
	var flags: Dictionary = _tools.flags()
	if bool(flags.get("uidebug", false)):
		_draw_grid()
	if bool(flags.get("ai", false)) and _to_screen.is_valid():
		_draw_ai()


func _draw_grid() -> void:
	var vp := get_viewport_rect().size
	var minor := Color(0.35, 0.95, 0.5, 0.08)
	var major := Color(0.35, 0.95, 0.5, 0.25)
	var x := 0.0
	while x <= vp.x:
		var is_major := int(x) % 100 == 0
		draw_line(Vector2(x, 0), Vector2(x, vp.y), major if is_major else minor)
		if is_major:
			draw_string(DevUI.mono(), Vector2(x + 2, 11), str(int(x)), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, DevUI.GREEN)
		x += 50.0
	var y := 0.0
	while y <= vp.y:
		var is_major := int(y) % 100 == 0
		draw_line(Vector2(0, y), Vector2(vp.x, y), major if is_major else minor)
		if is_major and y > 0:
			draw_string(DevUI.mono(), Vector2(2, y - 2), str(int(y)), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, DevUI.GREEN)
		y += 50.0
	var m := get_local_mouse_position()
	draw_line(Vector2(m.x, 0), Vector2(m.x, vp.y), Color(1, 1, 1, 0.3))
	draw_line(Vector2(0, m.y), Vector2(vp.x, m.y), Color(1, 1, 1, 0.3))
	draw_string(DevUI.mono(), m + Vector2(8, -8), "%d, %d   viewport %d×%d" % [m.x, m.y, vp.x, vp.y],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DevUI.GREEN)


func _draw_ai() -> void:
	var rows = JSON.parse_string(_tools.dbg.ai_overlay_rows())
	if not (rows is Array):
		return
	var colors := {"red": Color(0.95, 0.35, 0.3), "amber": Color(1, 0.75, 0.3), "cyan": Color(0.4, 0.85, 0.95),
		"green": Color(0.4, 0.9, 0.45), "grey": Color(0.75, 0.75, 0.78)}
	for r in rows:
		var from: Vector2 = _to_screen.call(Vector2(float(r.x), float(r.y)))
		if r.has("tx"):
			draw_line(from, _to_screen.call(Vector2(float(r.tx), float(r.ty))), Color(0.95, 0.3, 0.25, 0.7), 1.0)
		if r.has("lx"):
			draw_line(from, _to_screen.call(Vector2(float(r.lx), float(r.ly))), Color(0.4, 0.9, 0.45, 0.7), 1.0)
		var label_pos := from + Vector2(-24, -float(r.r) - 6)
		draw_string(DevUI.mono(), label_pos, str(r.text), HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			colors.get(str(r.kind), colors["grey"]))

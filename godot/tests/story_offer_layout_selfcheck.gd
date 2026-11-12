# Layout regression: the Nova Swift (modern) mission-offer dialog must give its title the row's width. It sat in an
# HBoxContainer as a word-wrapping Label with no expand flag, got ~0 px, and was drawn one letter per line.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/story_offer_layout_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const Spaceport = preload("res://screens/Spaceport.gd")
const StoryScreens = preload("res://screens/StoryScreens.gd")

var nova
var fails := 0


func _ok(cond: bool, what: String, detail := "") -> void:
	print(("PASS " if cond else "FAIL ") + what + ((" -- " + detail) if detail != "" else ""))
	if not cond:
		fails += 1


func _frames(n := 4) -> void:
	for i in n:
		await process_frame


func _init() -> void:
	_run()


func _find_label(n: Node, text: String) -> Label:
	if n is Label and (n as Label).text == text:
		return n
	for c in n.get_children():
		var hit := _find_label(c, text)
		if hit != null:
			return hit
	return null


func _run() -> void:
	get_root().size = Vector2i(1280, 720)
	Prefs.path = OS.get_user_data_dir() + "/story_offer_layout_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Prefs.apply_ui_mode(Prefs.UI_NOVA_SWIFT)   # the modern dialogs
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	if not nova.load_game(OS.get_environment("NOVA_DATA_DIR")):
		print("FAIL no game data")
		quit(1)
		return
	T.setup(nova)
	var scen = JSON.parse_string(nova.pilot_scenarios())
	nova.pilot_create(OS.get_user_data_dir() + "/story_offer_layout", int(scen[0].id), "Layout Tester", true, "", "")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	# A new pilot's first landing (Ryll, the starting stellar) brings the "Head to Sol" offer.
	var docked := false
	for id in range(128, 1600):
		if nova.debug_dock_at(id) and str(JSON.parse_string(nova.spaceport_info()).get("name", "")) == "Ryll":
			docked = true
			break
	_ok(docked, "docked at Ryll")
	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	var ss = StoryScreens.new()
	root.add_child(ss)
	ss.setup(nova)
	sp.open()
	await _frames()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	_ok(nova.offer_pending(), "an offer is pending on the first landing")
	var o = JSON.parse_string(nova.offer_state())
	var title := str(o.get("title", "")) if o is Dictionary else ""
	_ok(title != "", "the offer has a title", title)
	ss._open_offer()
	await _frames(6)
	var l := _find_label(ss, title)
	_ok(l != null, "the title label is in the dialog")
	if l != null:
		var font := l.get_theme_font("font")
		var want := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x
		_ok(l.size.x >= want, "the title gets at least its own width", "%.0f px for %.0f px of text" % [l.size.x, want])
		_ok(l.get_line_count() == 1, "the title is one line", str(l.get_line_count()) + " lines")
	print("STORY OFFER LAYOUT: " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)

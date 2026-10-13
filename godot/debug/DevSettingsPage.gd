# NOVA Swift — Settings > Support page (Apple SettingsView "Support" + "Developer" sections).
#
#   Support    Report a Bug (always available): opens the Report tab of the debug suite.
#   Developer  "Debug mode" (Prefs developer/debug_mode == GameSettings.debugModeEnabled). On:
#              the corner chip, F12 / Ctrl+` / L3+R3, and a pause-menu "Debug Suite" entry
#              appear; the buttons below open the suite. Off: none of it exists.
extends RefCounted

const DevUI = preload("res://debug/DevUI.gd")
const ShellUI = preload("res://screens/ShellUI.gd")
const Prefs = preload("res://Prefs.gd")


## `settings` is the Settings screen (for first_control / its page rebuild), `content` its page box.
static func build(settings: Node, content: VBoxContainer, mark_changed: Callable) -> void:
	var tree := settings.get_tree()
	var report := Button.new()
	report.text = "Report a Bug…"
	report.custom_minimum_size = Vector2(260, 38)
	report.pressed.connect(func(): tree.call_group("nova_devtools", "open_tab", "report"))
	content.add_child(report)
	if settings.first_control == null:
		settings.first_control = report
	ShellUI.label(content, "Builds a report you can share: your description plus the pilot save, the recent game log and a self-test. None of your imported EV Nova data is included.", 13)
	var dev := CheckButton.new()
	dev.text = "Debug mode"
	dev.button_pressed = bool(Prefs.get_value("developer", "debug_mode"))
	dev.custom_minimum_size = Vector2(0, 38)
	dev.toggled.connect(func(on: bool):
		Prefs.set_value("developer", "debug_mode", on)
		mark_changed.call()
		settings.show_page.call_deferred("Support"))
	content.add_child(dev)
	if dev.button_pressed:
		var open := Button.new()
		open.text = "Open Debug Suite"
		open.custom_minimum_size = Vector2(260, 38)
		open.pressed.connect(func(): tree.call_group("nova_devtools", "open_tab", "console"))
		content.add_child(open)
	ShellUI.label(content, "Shows an in-game debug chip and opens the debug suite (console, tools, state editor, control-bit browser, diagnostics, self-tests) with F12, Ctrl+` or both stick clicks on a pad.", 13)

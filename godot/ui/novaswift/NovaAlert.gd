# NOVA Swift — NovaSwift UI kit: alert / confirm, the Godot form of NovaAlert.swift (`.novaAlert`).
#
# The same choice SwiftUI's alert makes, drawn as a NovaDialog (Chrome.dialog) so a pad can operate
# it: amber title, white body message, optional text field, footer buttons — cancel first
# (leftmost), then the rest in order; the default (Return / pad confirm) is the last non-cancel,
# non-destructive button, never a delete; Esc / pad B = the cancel button. Every button runs its
# callback and then dismisses the alert.
#
#   Alert.show(self, {"title": "Delete pilot?", "message": "...", "buttons": [
#       {"title": "Cancel", "role": "cancel"},
#       {"title": "Delete", "role": "destructive", "cb": func(): ...}]})
#   Alert.show(self, {"title": "Rename Pilot", "text": "TEster3", "buttons": [
#       {"title": "Cancel", "role": "cancel"}, {"title": "Save", "cb": func(text): ...}]})
#
# With `text` set, button callbacks that accept one argument receive the field's text. With no
# buttons, a single OK. `host` is any Node; the alert lives on its own CanvasLayer (layer 200) so
# it covers whatever screen raised it. Returns {layer, dialog, field}.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")


static func show(host: Node, opts: Dictionary) -> Dictionary:
	var layer := CanvasLayer.new()
	layer.layer = 200
	layer.name = "NovaAlert"
	host.add_child(layer)
	var buttons: Array = opts.get("buttons", [])
	if buttons.is_empty():
		buttons = [{"title": "OK", "role": "cancel"}]
	var ordered: Array = buttons.filter(func(b): return b.get("role", "normal") == "cancel")
	ordered.append_array(buttons.filter(func(b): return b.get("role", "normal") != "cancel"))
	var default_i := -1
	for i in ordered.size():
		if ordered[i].get("role", "normal") == "normal":
			default_i = i
	var field: Array = [null]
	var specs: Array = []
	for i in ordered.size():
		var b: Dictionary = ordered[i]
		var cbf: Callable = b.get("cb", Callable())
		specs.append({"text": b.get("title", "OK"), "default": i == default_i or (default_i < 0 and ordered.size() == 1),
			"cancel": b.get("role", "normal") == "cancel", "destructive": b.get("role", "normal") == "destructive",
			"cb": func():
				var f: LineEdit = field[0]
				var text := f.text if f != null else ""
				if is_instance_valid(layer):
					layer.queue_free()
				if cbf.is_valid():
					if f != null and cbf.get_argument_count() >= 1:
						cbf.call(text)
					else:
						cbf.call()})
	var d := Chrome.dialog(layer, {"title": opts.get("title", ""), "width": opts.get("width", 420.0), "buttons": specs})
	var body: VBoxContainer = d.body
	var msg: String = opts.get("message", "")
	if msg != "":
		var l := NC.label(body, msg, "body", "regular", T.WHITE, true)
		l.custom_minimum_size = Vector2(300, 0)
	if opts.has("text"):
		var e := NC.text_field(str(opts.get("placeholder", opts.get("title", ""))), str(opts.text))
		body.add_child(e)
		field[0] = e
		e.select_all()
		Chrome.T_focus(e)
		e.text_submitted.connect(func(_t): if d.default != null: (d.default as BaseButton).pressed.emit())
	d["layer"] = layer
	d["field"] = field[0]
	return d

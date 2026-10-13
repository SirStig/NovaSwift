# NOVA Swift — NovaSwift UI kit: making a screen inert while another is stacked over it.
#
# The Apple app presents Settings, Plug-ins, the pilot list, the Story Map, About, Data Setup ...
# as overlays: the screen underneath stays drawn but cannot be operated, and closing the overlay
# hands focus back to exactly the control that opened it. Godot's focus navigation reaches controls
# in any CanvasLayer, so a scrim alone is not enough. `hold()` takes the underneath screen's
# controls out of focus navigation (focus_mode NONE) and its nodes out of the keyboard / pad input
# path (_input / _unhandled_input off), but leaves processing alone — animations, title music and
# the paused sim's own bookkeeping keep running. `release()` puts everything back.
#
#   var token := Inert.hold(menu)      # remembers the focused control too
#   ...                                # overlay up
#   Inert.release(token)               # restores focus on the opener (grab_focus), else `fallback`
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted


## Take `under` (a Node tree) out of input / focus navigation. Returns a token for release().
static func hold(under: Node) -> Dictionary:
	var tok := {"under": under, "focus": null, "controls": [], "inputs": []}
	if under == null or not under.is_inside_tree():
		return tok
	var fo := under.get_viewport().gui_get_focus_owner()
	if fo != null and (fo == under or under.is_ancestor_of(fo)):
		tok["focus"] = fo
	_walk(under, tok)
	return tok


static func _walk(n: Node, tok: Dictionary) -> void:
	if n is Control:
		var c: Control = n
		if c.focus_mode != Control.FOCUS_NONE:
			tok["controls"].append([c, c.focus_mode])
			if c.has_focus():
				c.release_focus()
			c.focus_mode = Control.FOCUS_NONE
	var flags := 0
	if n.is_processing_input():
		flags |= 1
		n.set_process_input(false)
	if n.is_processing_unhandled_input():
		flags |= 2
		n.set_process_unhandled_input(false)
	if n.is_processing_unhandled_key_input():
		flags |= 4
		n.set_process_unhandled_key_input(false)
	if flags != 0:
		tok["inputs"].append([n, flags])
	for ch in n.get_children():
		_walk(ch, tok)


## Undo hold(). Focus goes back to the control that had it (the opener); if that is gone,
## `fallback` is called (e.g. the screen's own refocus).
static func release(tok: Dictionary, fallback := Callable()) -> void:
	for pair in tok.get("controls", []):
		if is_instance_valid(pair[0]):
			pair[0].focus_mode = pair[1]
	for pair in tok.get("inputs", []):
		var n: Node = pair[0]
		if not is_instance_valid(n):
			continue
		var f: int = pair[1]
		if f & 1:
			n.set_process_input(true)
		if f & 2:
			n.set_process_unhandled_input(true)
		if f & 4:
			n.set_process_unhandled_key_input(true)
	var fo = tok.get("focus")
	if fo != null and is_instance_valid(fo) and fo.is_inside_tree() and fo.is_visible_in_tree():
		fo.grab_focus.call_deferred()
	elif fallback.is_valid():
		fallback.call_deferred()


## True while `under` is held (its controls cannot take focus).
static func is_held(tok: Dictionary) -> bool:
	for pair in tok.get("controls", []):
		if is_instance_valid(pair[0]) and pair[0].focus_mode == Control.FOCUS_NONE:
			return true
	return false

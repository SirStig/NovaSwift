# NOVA Swift — Controls Editor keyboard layout table.
#
# build(preset) -> {"keys": [ {code, label, x, y, w, h, ext?: Rect2, locked?: bool} ], "size": Vector2}
# in key units (1u = a standard key). `code` is the Godot physical keycode (Controls.gd's
# currency); -1 is a decorative key nothing can bind (Mac fn). `ext` is a second rectangle of an
# L-shaped key (unused now). Presets: full (ANSI 104) · tkl (no numpad) · compact (laptop style:
# F-row + arrows squeezed in, no nav cluster / numpad).
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const FKEYS := [KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12]
const NUMBER_ROW := [[KEY_QUOTELEFT, "`"], [KEY_1, "1"], [KEY_2, "2"], [KEY_3, "3"], [KEY_4, "4"], [KEY_5, "5"],
	[KEY_6, "6"], [KEY_7, "7"], [KEY_8, "8"], [KEY_9, "9"], [KEY_0, "0"], [KEY_MINUS, "-"], [KEY_EQUAL, "="]]
const TOP_ROW := [[KEY_Q, "Q"], [KEY_W, "W"], [KEY_E, "E"], [KEY_R, "R"], [KEY_T, "T"], [KEY_Y, "Y"],
	[KEY_U, "U"], [KEY_I, "I"], [KEY_O, "O"], [KEY_P, "P"], [KEY_BRACKETLEFT, "["], [KEY_BRACKETRIGHT, "]"]]
const HOME_ROW := [[KEY_A, "A"], [KEY_S, "S"], [KEY_D, "D"], [KEY_F, "F"], [KEY_G, "G"], [KEY_H, "H"],
	[KEY_J, "J"], [KEY_K, "K"], [KEY_L, "L"], [KEY_SEMICOLON, ";"], [KEY_APOSTROPHE, "'"]]
const BOTTOM_ROW := [[KEY_Z, "Z"], [KEY_X, "X"], [KEY_C, "C"], [KEY_V, "V"], [KEY_B, "B"], [KEY_N, "N"],
	[KEY_M, "M"], [KEY_COMMA, ","], [KEY_PERIOD, "."], [KEY_SLASH, "/"]]


static func _k(keys: Array, code: int, label: String, x: float, y: float, w := 1.0, h := 1.0) -> void:
	keys.append({"code": code, "label": label, "x": x, "y": y, "w": w, "h": h})


## A run of letter-ish keys starting at x; returns the x after the run.
static func _run(keys: Array, row: Array, x: float, y: float, h := 1.0) -> float:
	for e in row:
		_k(keys, int(e[0]), str(e[1]), x, y, 1.0, h)
		x += 1.0
	return x


static func _fn_label(i: int) -> String:
	return "F%d" % (i + 1)


## Esc + F1..F12 with the TKL gaps.
static func _frow_gapped(keys: Array, y: float) -> void:
	_k(keys, KEY_ESCAPE, "Esc", 0, y)
	for i in 12:
		_k(keys, FKEYS[i], _fn_label(i), 2.0 + float(i) + 0.5 * floorf(i / 4.0), y)


## The ANSI/ISO alphanumeric block of Full/TKL/75%: rows y..y+4 (number row first). Width 15.
static func _main_block(keys: Array, y0: float) -> void:
	var x := _run(keys, NUMBER_ROW, 0, y0)
	_k(keys, KEY_BACKSPACE, "Backspace", x, y0, 2.0)
	_k(keys, KEY_TAB, "Tab", 0, y0 + 1, 1.5)
	x = _run(keys, TOP_ROW, 1.5, y0 + 1)
	_k(keys, KEY_BACKSLASH, "\\", 13.5, y0 + 1, 1.5)
	_k(keys, KEY_CAPSLOCK, "Caps", 0, y0 + 2, 1.75)
	x = _run(keys, HOME_ROW, 1.75, y0 + 2)
	_k(keys, KEY_ENTER, "Enter", x, y0 + 2, 2.25)
	_k(keys, KEY_SHIFT, "Shift", 0, y0 + 3, 2.25)
	x = _run(keys, BOTTOM_ROW, 2.25, y0 + 3)
	_k(keys, KEY_SHIFT, "Shift", x, y0 + 3, 2.75)


static func _bottom_std(keys: Array, y: float) -> void:
	_k(keys, KEY_CTRL, "Ctrl", 0, y, 1.25)
	_k(keys, KEY_META, "Super", 1.25, y, 1.25)
	_k(keys, KEY_ALT, "Alt", 2.5, y, 1.25)
	_k(keys, KEY_SPACE, "Space", 3.75, y, 6.25)
	_k(keys, KEY_ALT, "Alt", 10.0, y, 1.25)
	_k(keys, KEY_META, "Super", 11.25, y, 1.25)
	_k(keys, KEY_MENU, "Menu", 12.5, y, 1.25)
	_k(keys, KEY_CTRL, "Ctrl", 13.75, y, 1.25)


static func _arrows_inline(keys: Array, x: float, y_up: float) -> void:
	_k(keys, KEY_UP, "↑", x + 1, y_up)
	_k(keys, KEY_LEFT, "←", x, y_up + 1)
	_k(keys, KEY_DOWN, "↓", x + 1, y_up + 1)
	_k(keys, KEY_RIGHT, "→", x + 2, y_up + 1)


static func _nav_cluster(keys: Array, x: float, y0: float) -> void:
	# y0 = the number row's y.
	for i in 3:
		_k(keys, [KEY_PRINT, KEY_SCROLLLOCK, KEY_PAUSE][i], ["Prt", "ScrLk", "Pause"][i], x + i, y0 - 1.5)
		_k(keys, [KEY_INSERT, KEY_HOME, KEY_PAGEUP][i], ["Ins", "Home", "PgUp"][i], x + i, y0)
		_k(keys, [KEY_DELETE, KEY_END, KEY_PAGEDOWN][i], ["Del", "End", "PgDn"][i], x + i, y0 + 1)
	_arrows_inline(keys, x, y0 + 3)


static func _numpad(keys: Array, x: float, y0: float) -> void:
	_k(keys, KEY_NUMLOCK, "Num", x, y0)
	_k(keys, KEY_KP_DIVIDE, "/", x + 1, y0)
	_k(keys, KEY_KP_MULTIPLY, "*", x + 2, y0)
	_k(keys, KEY_KP_SUBTRACT, "-", x + 3, y0)
	_k(keys, KEY_KP_7, "7", x, y0 + 1)
	_k(keys, KEY_KP_8, "8", x + 1, y0 + 1)
	_k(keys, KEY_KP_9, "9", x + 2, y0 + 1)
	_k(keys, KEY_KP_ADD, "+", x + 3, y0 + 1, 1.0, 2.0)
	_k(keys, KEY_KP_4, "4", x, y0 + 2)
	_k(keys, KEY_KP_5, "5", x + 1, y0 + 2)
	_k(keys, KEY_KP_6, "6", x + 2, y0 + 2)
	_k(keys, KEY_KP_1, "1", x, y0 + 3)
	_k(keys, KEY_KP_2, "2", x + 1, y0 + 3)
	_k(keys, KEY_KP_3, "3", x + 2, y0 + 3)
	_k(keys, KEY_KP_ENTER, "Enter", x + 3, y0 + 3, 1.0, 2.0)
	_k(keys, KEY_KP_0, "0", x, y0 + 4, 2.0)
	_k(keys, KEY_KP_PERIOD, ".", x + 2, y0 + 4)


static func _compact(keys: Array) -> void:
	var fh := 0.62
	_k(keys, KEY_ESCAPE, "Esc", 0, 0, 1.0, fh)
	for i in 12:
		_k(keys, FKEYS[i], _fn_label(i), 1.0 + i, 0, 1.0, fh)
	var y0 := fh + 0.18
	var x := _run(keys, NUMBER_ROW, 0, y0)
	_k(keys, KEY_BACKSPACE, "Backspace", x, y0, 1.5)
	_k(keys, KEY_TAB, "Tab", 0, y0 + 1, 1.5)
	x = _run(keys, TOP_ROW, 1.5, y0 + 1)
	_k(keys, KEY_BACKSLASH, "\\", x, y0 + 1, 1.0)
	_k(keys, KEY_CAPSLOCK, "Caps", 0, y0 + 2, 1.75)
	x = _run(keys, HOME_ROW, 1.75, y0 + 2)
	_k(keys, KEY_ENTER, "Enter", x, y0 + 2, 14.5 - x)
	_k(keys, KEY_SHIFT, "Shift", 0, y0 + 3, 2.25)
	x = _run(keys, BOTTOM_ROW, 2.25, y0 + 3)
	_k(keys, KEY_SHIFT, "Shift", x, y0 + 3, 14.5 - x)
	var y := y0 + 4
	_k(keys, KEY_CTRL, "Ctrl", 0, y, 1.25)
	_k(keys, KEY_META, "Super", 1.25, y, 1.25)
	_k(keys, KEY_ALT, "Alt", 2.5, y, 1.25)
	_k(keys, KEY_SPACE, "Space", 3.75, y, 5.75)
	_k(keys, KEY_ALT, "Alt", 9.5, y)
	_k(keys, KEY_CTRL, "Ctrl", 10.5, y)
	_k(keys, KEY_LEFT, "←", 11.5, y + 0.5, 1.0, 0.5)
	_k(keys, KEY_UP, "↑", 12.5, y, 1.0, 0.5)
	_k(keys, KEY_DOWN, "↓", 12.5, y + 0.5, 1.0, 0.5)
	_k(keys, KEY_RIGHT, "→", 13.5, y + 0.5, 1.0, 0.5)


static func build(preset: String) -> Dictionary:
	var keys: Array = []
	match preset:
		"compact":
			_compact(keys)
		_:
			_frow_gapped(keys, 0.0)
			_main_block(keys, 1.5)
			_bottom_std(keys, 5.5)
			_nav_cluster(keys, 15.5, 1.5)
			if preset == "full":
				_numpad(keys, 19.0, 1.5)
	var w := 0.0
	var h := 0.0
	for k in keys:
		w = maxf(w, float(k.x) + float(k.w))
		h = maxf(h, float(k.y) + float(k.h))
	return {"keys": keys, "size": Vector2(w, h)}


## Every key code the preset draws.
static func codes(preset: String) -> Dictionary:
	var out: Dictionary = {}
	for k in build(preset).keys:
		if int(k.code) >= 0:
			out[int(k.code)] = true
	return out

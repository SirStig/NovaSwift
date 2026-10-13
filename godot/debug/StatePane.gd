# NOVA Swift — State tab (port of DebugGameStateView.swift): live pilot / ship / world state with
# editors. Sections as on Apple: Pilot (credits + quick adds, combat rating), Ship (hull, opens the
# Ships tab), Ship Health (shield / armor / fuel sliders on the live ship + Full heal · Refuel ·
# Damage), Cheats, Fleet (escorts, hostiles), Time (day / month / year + quick advances), Relations
# (legal record here), Mission control bits (set / clear / toggle + the held list), Outfits
# (grant all / clear, per-outfit +/-), Spawn enemies. Every action submits a console command.
# The labels refresh twice a second; the layout is built once (so focus is never disturbed).
extends ScrollContainer

const DevUI = preload("res://debug/DevUI.gd")

var _tools: Node
var _col: VBoxContainer
var _timer := 0.0
var _w := {}                     # widget refs by key
var _bits_sig := ""
var _outfits_sig := ""
var _bits_box: VBoxContainer
var _outfits_box: VBoxContainer
var _updating := false


func setup(tools: Node) -> void:
	_tools = tools
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col = DevUI.vbox(self, 8)
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build()
	tick(10.0)


func on_show() -> void:
	tick(10.0)


func focus_first() -> void:
	if _w.has("credits"):
		_w["credits"].grab_focus()


func tick(delta: float) -> void:
	_timer += delta
	if _timer < 0.5:
		return
	_timer = 0.0
	_refresh()


func _run(cmd: String) -> void:
	_tools.run(cmd)
	_refresh()


func _chip(parent: Node, title: String, cmd: String, tint := DevUI.GREEN) -> Button:
	return DevUI.button(parent, title, func(): _run(cmd), tint)


func _section(title: String, footer := "") -> VBoxContainer:
	var card := DevUI.card(_col)
	DevUI.label(card, title.to_upper(), 11, DevUI.GREEN)
	var body := DevUI.vbox(card, 5)
	if footer != "":
		DevUI.wrap_label(card, footer, 10)
	return body


func _kv(parent: Node, key: String, title: String) -> Label:
	var r := DevUI.hbox(parent, 8)
	var k := DevUI.label(r, title, 12, DevUI.DIM)
	k.custom_minimum_size = Vector2(140, 0)
	var v := DevUI.label(r, "—", 12, Color.WHITE)
	_w[key] = v
	return v


func _spin(parent: Node, key: String, lo: float, hi: float, step: float, on_change: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(120, 0)
	s.value_changed.connect(func(v: float):
		if not _updating:
			on_change.call(v))
	parent.add_child(s)
	_w[key] = s
	return s


func _slider(parent: Node, key: String, title: String, stat: String) -> void:
	var r := DevUI.hbox(parent, 8)
	var k := DevUI.label(r, title, 12, DevUI.DIM)
	k.custom_minimum_size = Vector2(140, 0)
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = 100
	s.step = 1
	s.custom_minimum_size = Vector2(240, 22)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_ALL
	# Apply when the value settles (drag released, or a key / pad step), not on every pixel.
	s.drag_ended.connect(func(changed: bool):
		if changed:
			_run("set %s %d" % [stat, int(s.value)]))
	s.value_changed.connect(func(v: float):
		if not _updating and not s.has_meta("dragging") and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) == false:
			_run("set %s %d" % [stat, int(v)]))
	r.add_child(s)
	var l := DevUI.label(r, "—", 11, DevUI.DIM)
	_w[key] = s
	_w[key + "_l"] = l


func _build() -> void:
	# Pilot
	var pilot := _section("Pilot")
	var r := DevUI.hbox(pilot, 8)
	var k := DevUI.label(r, "Credits", 12, DevUI.DIM)
	k.custom_minimum_size = Vector2(140, 0)
	var cr := LineEdit.new()
	cr.custom_minimum_size = Vector2(150, 0)
	cr.text_submitted.connect(func(t: String):
		if t.is_valid_int():
			_run("credits set %d" % int(t)))
	r.add_child(cr)
	_w["credits"] = cr
	_chip(r, "+10k", "credits add 10000")
	_chip(r, "+100k", "credits add 100000")
	_chip(r, "+1M", "credits add 1000000")
	_chip(r, "Zero", "credits set 0", DevUI.RED)
	var rr := DevUI.hbox(pilot, 8)
	var rk := DevUI.label(rr, "Combat rating", 12, DevUI.DIM)
	rk.custom_minimum_size = Vector2(140, 0)
	var rs := _spin(rr, "rating", 0, 1000000, 100, func(v: float): _run("rating %d" % int(v)))
	rs.set_meta("kind", "rating")
	_kv(pilot, "date", "Date")
	_kv(pilot, "where", "System")

	# Ship
	var ship := _section("Ship", "Hull and outfit changes apply the next time the ship is rebuilt (takeoff, jump, or landing/departure) — or run `rebuild`.")
	var sr := DevUI.hbox(ship, 8)
	var sk := DevUI.label(sr, "Current ship", 12, DevUI.DIM)
	sk.custom_minimum_size = Vector2(140, 0)
	_w["ship"] = DevUI.label(sr, "—", 12, Color.WHITE)
	DevUI.button(sr, "Choose…  ›", func(): _tools.open_tab("ships"), DevUI.GREEN)
	_chip(sr, "Rebuild now", "rebuild")

	# Health
	var health := _section("Ship health", "Shield, armor and fuel act on the ship you're flying right now.")
	_slider(health, "shield", "Shield", "shield")
	_slider(health, "armor", "Armor (hull)", "armor")
	_slider(health, "fuel", "Fuel", "fuel")
	var hr := DevUI.hbox(health, 6)
	_chip(hr, "Full heal", "heal")
	_chip(hr, "Refuel", "refuel")
	_chip(hr, "Damage", "damage", DevUI.RED)

	# Cheats
	var cheats := _section("Cheats", "Toggles take effect the moment you're flying.")
	for t in [["God mode — no damage", "god"], ["Infinite fuel", "fuel"]]:
		var row := DevUI.hbox(cheats, 8)
		var l := DevUI.label(row, t[0], 12)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var c := CheckButton.new()
		var cmd: String = t[1]
		c.toggled.connect(func(on: bool):
			if not _updating:
				_run("%s %s" % [cmd, "on" if on else "off"]))
		row.add_child(c)
		_w["cheat_" + cmd] = c

	# Fleet
	var fleet := _section("Fleet")
	_kv(fleet, "fleet", "Escorts · hostile")
	var fr := DevUI.hbox(fleet, 8)
	DevUI.label(fr, "Escorts to add", 12, DevUI.DIM)
	var es := _spin(fr, "escort_n", 1, 12, 1, func(_v): pass)
	es.value = 2
	DevUI.button(fr, "Add escorts", func(): _run("escorts %d" % int(es.value)), DevUI.GREEN)
	var fr2 := DevUI.hbox(fleet, 6)
	_chip(fr2, "Disable hostiles", "hostiles disable")
	_chip(fr2, "Destroy hostiles", "hostiles destroy", DevUI.RED)
	_chip(fr2, "Clear all NPCs", "clearnpcs", DevUI.RED)

	# Time
	var time := _section("Time")
	var tr := DevUI.hbox(time, 8)
	for part in [["Day", "day", 1, 31], ["Month", "month", 1, 12], ["Year", "year", 0, 9999]]:
		DevUI.label(tr, part[0], 12, DevUI.DIM)
		_spin(tr, "date_" + part[1], part[2], part[3], 1, func(_v): _apply_date())
	var tr2 := DevUI.hbox(time, 6)
	_chip(tr2, "+1 day", "date +1")
	_chip(tr2, "+30 days", "date +30")
	_chip(tr2, "+1 year", "date +365")

	# Relations
	var rel := _section("Relations")
	_kv(rel, "rep", "Legal record here")
	var rl := DevUI.hbox(rel, 6)
	_chip(rl, "Hostile here", "relation -30000", DevUI.RED)
	_chip(rl, "Neutral here", "relation 0")
	_chip(rl, "Friendly here", "relation 30000")
	DevUI.label(rl, "or", 11, DevUI.DIM)
	var rv := LineEdit.new()
	rv.placeholder_text = "value"
	rv.custom_minimum_size = Vector2(90, 0)
	rv.text_submitted.connect(func(t: String):
		if t.is_valid_int():
			_run("relation %d" % int(t)))
	rl.add_child(rv)

	# Control bits
	var bits := _section("Mission control bits (NCB)", "Browse every bit and what sets / tests it in the Bits tab.")
	var br := DevUI.hbox(bits, 6)
	DevUI.label(br, "Bit", 12, DevUI.DIM)
	var bn := _spin(br, "bit_n", 0, 10000, 1, func(_v): pass)
	DevUI.button(br, "Set", func(): _run("bit set %d" % int(bn.value)), DevUI.GREEN)
	DevUI.button(br, "Clear", func(): _run("bit clear %d" % int(bn.value)), DevUI.RED)
	DevUI.button(br, "Toggle", func(): _run("bit toggle %d" % int(bn.value)), DevUI.GREEN)
	DevUI.button(br, "Explain", func(): _run("bit info %d" % int(bn.value)), DevUI.BLUE)
	_w["bits_title"] = DevUI.label(bits, "—", 11, DevUI.DIM)
	_bits_box = DevUI.vbox(bits, 3)

	# Outfits
	var outfits := _section("Outfits", "Browse and grant individual outfits in the Outfits tab.")
	_w["outfits_title"] = DevUI.label(outfits, "—", 11, DevUI.DIM)
	var orow := DevUI.hbox(outfits, 6)
	_chip(orow, "Grant every outfit", "outfits all")
	_chip(orow, "Clear all", "outfits clear", DevUI.RED)
	_outfits_box = DevUI.vbox(outfits, 3)

	# Spawn
	var spawn := _section("Spawn enemies", "Armed ships appear near you, provoked and locked on.")
	var sp := DevUI.hbox(spawn, 8)
	DevUI.label(sp, "Count", 12, DevUI.DIM)
	var sn := _spin(sp, "spawn_n", 1, 50, 1, func(_v): pass)
	sn.value = 3
	DevUI.button(sp, "Spawn hostiles", func(): _run("hostiles spawn %d" % int(sn.value)), DevUI.RED)


func _apply_date() -> void:
	_run("date set %d %d %d" % [int(_w["date_day"].value), int(_w["date_month"].value), int(_w["date_year"].value)])


func _refresh() -> void:
	var st: Dictionary = _tools.overlay_state()
	if st.is_empty() or not st.has("pilot"):
		return
	_updating = true
	var p: Dictionary = st.pilot
	if not _w["credits"].has_focus():
		_w["credits"].text = str(int(p.credits))
	_set_spin("rating", int(p.combatRating))
	_w["date"].text = str(p.date)
	_w["where"].text = "%s (#%d)%s" % [p.systemName, int(p.system), "  · landed" if int(p.landed) >= 0 else ""]
	_w["ship"].text = "%s (#%d)" % [p.shipName, int(p.shipType)]
	_w["rep"].text = str(int(p.reputationHere))
	var cheats: Dictionary = st.get("cheats", {})
	_w["cheat_god"].set_pressed_no_signal(bool(cheats.get("god", false)))
	_w["cheat_fuel"].set_pressed_no_signal(bool(cheats.get("fuel", false)))
	if st.has("ship"):
		var s: Dictionary = st.ship
		_set_slider("shield", float(s.shield), float(s.maxShield))
		_set_slider("armor", float(s.armor), float(s.maxArmor))
		_set_slider("fuel", float(s.fuel), float(s.maxFuel))
	else:
		for k in ["shield", "armor", "fuel"]:
			_w[k + "_l"].text = "no live ship"
	if st.has("world"):
		_w["fleet"].text = "%d · %d  (%d ships in system)" % [int(st.world.escorts), int(st.world.hostiles), int(st.world.ships)]
	var d := str(p.date)
	var parts := d.replace("/", "-").split("-")
	_set_date_spins(d)
	# bits
	var bits: Array = p.bits
	_w["bits_title"].text = "%d bit(s) held" % bits.size()
	var bsig := str(bits)
	if bsig != _bits_sig:
		_bits_sig = bsig
		DevUI.clear_children(_bits_box)
		var flow := DevUI.flow(_bits_box, 4)
		for b in bits.slice(0, 120):
			var bn: int = int(b)
			DevUI.button(flow, "b%d ✕" % bn, func(): _run("bit clear %d" % bn), DevUI.DIM)
	# outfits
	var outfits: Array = p.outfits
	var total := 0
	for o in outfits:
		total += int(o.count)
	_w["outfits_title"].text = "%d item(s) owned (%d kinds)" % [total, outfits.size()]
	var osig := str(outfits)
	if osig != _outfits_sig:
		_outfits_sig = osig
		DevUI.clear_children(_outfits_box)
		for o in outfits.slice(0, 80):
			var id: int = int(o.id)
			var row := DevUI.hbox(_outfits_box, 6)
			DevUI.label(row, "×%d  #%d  %s" % [int(o.count), id, str(o.name)], 11, Color(1, 1, 1, 0.8))
			DevUI.button(row, "+", func(): _run("outfit add %d" % id), DevUI.GREEN)
			DevUI.button(row, "−", func(): _run("outfit remove %d" % id), DevUI.RED)
	_updating = false


func _set_spin(key: String, v: int) -> void:
	var s: SpinBox = _w[key]
	if not s.get_line_edit().has_focus():
		s.set_value_no_signal(v)


func _set_slider(key: String, cur: float, mx: float) -> void:
	var s: HSlider = _w[key]
	var frac := (cur / mx * 100.0) if mx > 0.0 else 0.0
	if not s.has_focus():
		s.set_value_no_signal(clampf(frac, 0.0, 100.0))
	_w[key + "_l"].text = "%d / %d" % [int(cur), int(mx)]


## `GameDate.description` is "DD Mon YYYY"-ish text; the spinboxes show the numeric parts the
## console accepts, taken from the state when available.
func _set_date_spins(text: String) -> void:
	var nums := []
	var cur := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			cur += ch
		elif cur != "":
			nums.append(int(cur))
			cur = ""
	if cur != "":
		nums.append(int(cur))
	# Only trust a clean three-number date; otherwise leave the spinboxes alone.
	if nums.size() == 3:
		for pair in [["date_day", nums[0]], ["date_month", nums[1]], ["date_year", nums[2]]]:
			_set_spin(pair[0], pair[1])

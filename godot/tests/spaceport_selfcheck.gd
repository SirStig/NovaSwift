# Headless self-check for the spaceport bridge calls: land, trade, outfitter,
# shipyard, pictures, and the fuel round trip (jump -> land -> below max ->
# Recharge costs exactly what LandedServices.refuel says -> launch carries it).
# Credits must change by exactly the listed prices. Run:
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/spaceport_selfcheck.gd
# Prints SPACEPORT SELFCHECK: PASS / FAIL.
extends SceneTree

var nova
var ok := true


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _init() -> void:
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var dir := OS.get_user_data_dir() + "/spaceport_selfcheck"
	_check("load_game", nova.load_game(data))
	var scen = JSON.parse_string(nova.pilot_scenarios())
	var rich = scen[0]
	for sc in scen:
		if int(sc.cash) > int(rich.cash):
			rich = sc
	print("scenario: ", rich)
	var id: String = nova.pilot_create(dir, int(rich.id), "Port Tester", true, "", "")
	_check("pilot created", id != "")
	_check("make_world", nova.make_world(-1))
	nova.step(1.0 / 30.0)

	# --- land at the starting stellar (launch placed us next to it, at rest)
	_check("attempt_land at start", nova.attempt_land())
	_shop_checks()
	_check("launch", nova.launch())

	# --- fuel round trip
	_fuel_checks()

	nova.pilot_delete(dir, id)
	print("SPACEPORT SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _shop_checks() -> void:
	var info = JSON.parse_string(nova.spaceport_info())
	print("landed at ", info.name, " trade=", info.trade, " outfitter=", info.outfitter, " shipyard=", info.shipyard)
	_check("info has name + description", str(info.name) != "" and str(info.description) != "")
	var lp: int = nova.spaceport_picture_id(1, int(info.id))
	if lp >= 0:
		var wh: PackedInt32Array = nova.pict_info(lp)
		_check("landing picture decodes", wh.size() == 2 and nova.pict_rgba(lp).size() == wh[0] * wh[1] * 4,
			"PICT %d %s" % [lp, wh])
	else:
		print("  (no landing PICT for this stellar — sprite fallback)")

	# Trade Center
	if info.trade:
		var tv = JSON.parse_string(nova.trade_view())
		_check("trade rows listed", tv.rows.size() > 0)
		var c0: int = nova.player_credits()
		var free0: int = nova.cargo_free_tons()
		var want: int = nova.trade_quantity(0, true, -1)
		var price: int = int(tv.rows[0].price)
		var got: int = nova.trade_buy(0, want)
		_check("buy cargo: credits drop by price*tons", got > 0 and nova.player_credits() == c0 - got * price,
			"%d t @ %d: %d -> %d" % [got, price, c0, nova.player_credits()])
		_check("buy cargo: free space drops", nova.cargo_free_tons() == free0 - got)
		var sold: int = nova.trade_sell(0, got)
		_check("sell cargo returns the credits", sold == got and nova.player_credits() == c0)
		_check("typed quantity capped by credits/space",
			nova.trade_quantity(0, true, 32000) == mini(mini(c0 / price, free0), 32000))

	# Outfitter
	if info.outfitter:
		nova.outfitter_open()
		var list = JSON.parse_string(nova.outfitter_list())
		_check("outfitter lists items", list.size() > 0, "%d" % list.size())
		var cands: Array = []
		for it in list:
			if it.canBuy and int(it.price) > 0:
				cands.append(it)
		cands.sort_custom(func(x, y): return int(x.price) < int(y.price))
		_check("a buyable outfit exists", cands.size() > 0)
		for pick in cands:
			var c1: int = nova.player_credits()
			var owned0: int = int(pick.owned)
			var n: int = nova.outfitter_buy(int(pick.id), 1)
			_check("outfit buy: exact price", n == 1 and nova.player_credits() == c1 - int(pick.price),
				"%s %d cr" % [pick.name, int(pick.price)])
			var after = _find(JSON.parse_string(nova.outfitter_list()), int(pick.id))
			if after == null or int(after.owned) == owned0:
				print("  (", pick.name, " is consumed on purchase — trying the next outfit)")
				continue
			_check("owned count +1", int(after.owned) == owned0 + 1)
			var sale: int = int(after.salePrice)
			_check("outfit sell: exact sale price (bought this visit = full)",
				nova.outfitter_sell(int(pick.id), 1) == 1 and nova.player_credits() == c1 and sale == int(pick.price),
				"sale %d" % sale)
			_check("outfit description text", nova.outfitter_description(int(pick.id)) != "")
			print("  outfit picture PICT: ", nova.spaceport_picture_id(2, int(pick.id)))
			break

	# Shipyard
	if info.shipyard:
		var ships = JSON.parse_string(nova.shipyard_list())
		_check("shipyard lists hulls", ships.size() > 0, "%d" % ships.size())
		var si = JSON.parse_string(nova.shipyard_info(int(ships[0].id)))
		_check("ship info has stats", si.stats.size() > 0 and si.name != "")
		var buy = null
		for s in ships:
			print("    hull ", s.name, " net ", int(s.price), " canBuy=", s.canBuy, " locked=", s.locked)
			if s.canBuy and (buy == null or int(s.price) < int(buy.price)):
				buy = s
		if buy != null:
			var c2: int = nova.player_credits()
			var tin: int = int(JSON.parse_string(nova.shipyard_state()).tradeIn)
			_check("ship buy succeeds", nova.shipyard_buy(int(buy.id)))
			_check("ship buy: credits = before - net price (incl. trade-in %d)" % tin,
				nova.player_credits() == c2 - int(buy.price), "%s net %d" % [buy.name, int(buy.price)])
			var now = _find(JSON.parse_string(nova.shipyard_list()), int(buy.id))
			_check("new hull is current", now != null and now.current)
			if nova.has_method("stock_bank_size") and info.outfitter:
				# EC-09: the new hull's stock armament sits in the bank until the outfitter opens.
				var bank0: int = nova.stock_bank_size()
				nova.outfitter_open()
				_check("opening the outfitter promotes the stock bank", nova.stock_bank_size() == 0, "%d -> 0" % bank0)
		else:
			print("  (no affordable hull on a 25000 cr scenario — buy path not exercised here)")
			var c3: int = nova.player_credits()
			_check("unaffordable hull refused, credits untouched",
				not nova.shipyard_buy(int(ships[ships.size() - 1].id)) and nova.player_credits() == c3)
	# Not offered here -> refused
	_check("outfitter_buy of a bogus id refused", nova.outfitter_buy(999999, 1) == 0)


func _find(list, id: int):
	for it in list:
		if int(it.id) == id:
			return it
	return null


# Jump to a neighbouring system, fly to a landable body, land with a part-empty tank.
func _fuel_checks() -> void:
	nova.nav_refresh()
	var start: int = nova.nav_current_system()
	var links: PackedInt32Array = nova.nav_links()
	var dest := -1
	for i in range(0, links.size(), 2):
		if links[i] == start:
			dest = links[i + 1]
			break
		if links[i + 1] == start:
			dest = links[i]
			break
	if not _check("a linked neighbour exists", dest != -1):
		return
	nova.nav_click(dest)
	var tries := 0
	while tries < 3000:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		tries += 1
		if tries % 15 == 0:
			nova.begin_hyperjump()
			if nova.hyperjump_active():
				break
	var ticks := 0
	while nova.hyperjump_active() and ticks < 6000:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		ticks += 1
	_check("jumped", nova.take_jump_arrival() != "")
	var frac: float = nova.player_fuel_fraction()
	_check("fuel below max after a jump", frac < 0.999, "%.3f" % frac)

	if not _fly_and_land():
		print("  (could not land in the new system — refuel check skipped)")
		return
	var info = JSON.parse_string(nova.spaceport_info())
	print("fuel at ", info.name, ": ", info.fuel, "/", info.maxFuel, " jumps; uninhabited=", info.uninhabited)
	_check("pilot fuel carried into the dock", absf(float(info.fuel) / float(info.maxFuel) - frac) < 0.01)
	# Launch without refuelling: the tank must stay where it was.
	nova.launch()
	_check("launch carries the real fuel (not full)", absf(nova.player_fuel_fraction() - frac) < 0.01,
		"%.3f vs %.3f" % [nova.player_fuel_fraction(), frac])
	_check("re-land (placed at the stellar)", nova.attempt_land())
	info = JSON.parse_string(nova.spaceport_info())
	if info.uninhabited:
		_check("uninhabited port offers no Recharge", not info.needsRecharge and nova.spaceport_recharge() == -1)
		return
	_check("Recharge offered below max", info.needsRecharge)
	var c: int = nova.player_credits()
	var cap_units := int(round(float(info.maxFuel) * 100.0))
	var cur_units := int(float(info.fuel) * 100.0 + 0.0001)
	var expect := mini(cap_units - cur_units, c)
	var spent: int = nova.spaceport_recharge()
	_check("Recharge costs 1 cr per unit (LandedServices.refuel)", spent == expect and nova.player_credits() == c - spent,
		"spent %d expected %d" % [spent, expect])
	info = JSON.parse_string(nova.spaceport_info())
	_check("tank full after Recharge", not info.needsRecharge)
	nova.launch()
	_check("launch after Recharge is full", nova.player_fuel_fraction() > 0.999)


# Steer for the nearest landable body, coasting under the landing speed limit.
func _fly_and_land() -> bool:
	for t in 12000:
		if nova.can_land_now():
			return nova.attempt_land()
		var xf: PackedFloat32Array = nova.body_transforms()
		var p: Vector2 = nova.player_position()
		var best := -1
		var bd := INF
		for i in range(0, xf.size(), 4):
			if int(xf[i + 3]) != 0:
				continue
			var d := p.distance_to(Vector2(xf[i], xf[i + 1]))
			if d < bd:
				bd = d
				best = i
		if best < 0:
			return false
		var tgt := Vector2(xf[best], xf[best + 1])
		var dir := tgt - p
		if t % 3000 == 0:
			print("    fly t=", t, " dist=", int(dir.length()), " speed=", int(nova.player_velocity().length()), " ang=", snappedf(nova.player_angle(), 0.01), " want=", snappedf(atan2(dir.x, dir.y), 0.01), " vel=", nova.player_velocity())
		var v: Vector2 = nova.player_velocity()
		var thrust := false
		if v.length() > 95.0:
			# Too fast to land: point against the velocity and burn it off.
			var want: float = atan2(-v.x, -v.y)
			thrust = absf(angle_difference(nova.player_angle(), want)) < 0.35
		else:
			thrust = v.length() < 90.0 and dir.length() > float(xf[best + 2]) + 90.0 \
				and absf(angle_difference(nova.player_angle(), atan2(dir.x, dir.y))) < 0.35
		nova.set_intent(false, false, thrust, false, false, false, false)
		# set_intent resets the intent, so the aim heading goes in after it.
		var aim := atan2(-v.x, -v.y) if v.length() > 95.0 else atan2(dir.x, dir.y)
		nova.set_aim_heading(true, aim)
		nova.step(1.0 / 30.0)
	return false

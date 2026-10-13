# Headless "does this plug-in fully load and play" check, one plug-in (or plug-in combination) per run.
# Driven by scripts/plugins-check.sh, which stages the plug-in in a scratch folder and sets:
#   NOVA_PLUGINS_DIR     scratch folder holding ONLY the plug-in(s) under test (found like the user plug-in folder)
#   NOVA_PLUGIN_HOME     scratch data root (state file + Plug-ins folder);  NOVA_PLUGIN_STATE, NOVA_PILOTS_DIR likewise
#   NOVA_DATA_DIR        the base game data
#   NOVA_PLUGCHECK_NAME  label for the report
#   NOVA_PLUGCHECK_ENABLE  comma list of bundle ids to switch on under manual order (optional sub-items, TCs);
#                        empty = the original rule (everything loads) + any total conversion enabled
#   NOVA_PLUGCHECK_TCADDONS  "<tc id>=<plug-in id>[,<id>...]": put those installed plug-ins on the total conversion's own
#                        add-on list (the Plugins screen's "Add plug-in to <TC>") instead of staging files in its Plug-Ins
#   NOVA_PLUGCHECK_MEDIA JSON from `novaswift-extract desc-movies ...`: every dësc movie / font and whether the shared
#                        Swift resolution finds it; Godot must resolve the same files and be able to play them
#   NOVA_PLUGCHECK_REF   JSON from `novaswift-extract merged-counts ...` (the shared Swift code Apple uses): the
#                        per-type counts Godot must reproduce exactly
#   NOVA_PLUGCHECK_ALL   "1" = run the pilot flow for every chär start scenario (default: the first, quick-start
#                        smoke for the rest)
#   NOVA_PLUGCHECK_NOFLOW "1" = only the load / parity / asset checks
# Prints per-step "ok / FAIL / warn" lines, then `PLUGCHECK <name>: PASS|FAIL` and a `RESULT|...` summary row.
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const Renderer = preload("res://flight/FlightRenderer.gd")
const Sprites = preload("res://flight/FlightSprites.gd")
const GameAudio = preload("res://audio/GameAudio.gd")
const Spaceport = preload("res://screens/Spaceport.gd")
const GalaxyMap = preload("res://screens/GalaxyMap.gd")
const TitleMusic = preload("res://audio/TitleMusic.gd")
const Movies = preload("res://Movies.gd")
const StoryScreens = preload("res://screens/StoryScreens.gd")
const DescMovie = preload("res://ui/DescMovie.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

var ok: bool = true
var warns: int = 0
var checks: int = 0
var nova
var pl
var dbg
var audio
var rend
var label: String = ""
var work: String = ""
var data: String = ""
var summary: Dictionary = {}


func _check(what: String, cond: bool, detail: String = "") -> bool:
	checks += 1
	print(("  ok   " if cond else "  FAIL ") + what + ((" -- " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _warn(what: String, detail: String = "") -> void:
	warns += 1
	print("  warn " + what + ((" -- " + detail) if detail != "" else ""))


func _j(t: String):
	return JSON.parse_string(t)


func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	label = OS.get_environment("NOVA_PLUGCHECK_NAME")
	work = OS.get_environment("NOVA_PLUGCHECK_WORK")
	if work == "":
		work = OS.get_user_data_dir() + "/plugcheck"
	DirAccess.make_dir_recursive_absolute(work)
	data = OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	Prefs.path = work + "/settings.cfg"
	Prefs.load_all()
	Controls.register()
	print("== plug-in check: ", label)

	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	pl = ClassDB.instantiate("NovaPlugins")
	pl.attach(nova)
	dbg = ClassDB.instantiate("NovaDebug")
	dbg.attach(nova)

	var t0: int = Time.get_ticks_msec()
	_check("load_game (base + discovered plug-ins)", nova.load_game(data))
	_import_requested()
	_enable_requested()
	_tc_addons_requested()
	_check("reload with the chosen plug-in set", pl.reload())
	summary["load_ms"] = Time.get_ticks_msec() - t0
	var list: Array = _j(pl.list())
	var enabled_ids: Array = list.filter(func(p): return p.enabled).map(func(p): return p.id)
	print("   bundles: ", list.map(func(p): return "%s%s%s" % [p.id, " [TC]" if p.total_conversion else "", "" if p.enabled else " (off)"]))
	var st: Dictionary = _j(pl.state())
	_check("no resource file failed to parse", (st.failures as Array).is_empty(), str(st.failures))
	summary["bundles"] = list.size()
	summary["enabled"] = enabled_ids.size()

	_parity(enabled_ids)
	_asset_sweep()
	await _media_search(list)

	if OS.get_environment("NOVA_PLUGCHECK_NOFLOW") != "1":
		await _flow()

	print("PLUGCHECK %s: %s  (%d checks, %d warnings)" % [label, "PASS" if ok else "FAIL", checks, warns])
	print("RESULT|%s|%s|%s" % [label, "PASS" if ok else "FAIL", JSON.stringify(summary)])
	quit(0 if ok else 1)


## NOVA_PLUGCHECK_IMPORT=<zip | .rez | folder>: install through the bridge's import (the Plugins screen's
## "Import..."), which unpacks into the user Plug-ins folder, then rescan like the screen does.
func _import_requested() -> void:
	var src: String = OS.get_environment("NOVA_PLUGCHECK_IMPORT")
	if src == "":
		return
	var r = _j(pl.import_from(src))
	_check("import '%s' through the bridge" % src.get_file(), r is Dictionary and bool(r.ok), str(r) + " <- " + src)
	pl.rescan()
	_check("the import is listed and deletable", (_j(pl.list()) as Array).any(func(p): return p.deletable))


# --- 1. install / enable the way the Plugins screen does ---------------------------------------------

func _enable_requested() -> void:
	var want: PackedStringArray = OS.get_environment("NOVA_PLUGCHECK_ENABLE").split(",", false)
	var list: Array = _j(pl.list())
	if not want.is_empty():
		pl.set_manual_order(true)
		for id in want:
			_check("enable '%s' (manual order)" % id, pl.set_enabled(id, true))
		return
	for p in list:
		if p.total_conversion:
			_check("select total conversion '%s'" % p.id, pl.set_enabled(p.id, true))
			break


## NOVA_PLUGCHECK_TCADDONS: the per-conversion add-on list, driven through the same bridge calls as the screen.
func _tc_addons_requested() -> void:
	var spec: String = OS.get_environment("NOVA_PLUGCHECK_TCADDONS")
	if spec == "":
		return
	var parts: PackedStringArray = spec.split("=", false, 1)
	var tc: String = parts[0]
	var info: Variant = _j(pl.tc_addons())
	_check("the Plugins screen sees '%s' as the selected conversion" % tc, info is Dictionary and str((info as Dictionary).get("tc", "")) == tc)
	var want: PackedStringArray = parts[1].split(",", false) if parts.size() > 1 else PackedStringArray()
	for id in want:
		_check("add '%s' to %s's add-on list" % [id, tc], pl.tc_addon_add(tc, id))
	info = _j(pl.tc_addons())
	var listed: Array = []
	if info is Dictionary:
		for e in (info as Dictionary).get("list", []):
			listed.append(str(e.id))
	_check("the add-on list shows them in order", listed == Array(want), "%s vs %s" % [listed, want])
	# Suggestions: a plug-in named for the conversion (EVO ... for EV Override) is "recommended".
	for id in want:
		var row: Dictionary = {}
		for e in (info as Dictionary).get("list", []):
			if str(e.id) == id:
				row = e
		if str(id).begins_with("EVO") and tc.contains("Override"):
			_check("'%s' is marked made-for-this under %s" % [id, tc], str(row.get("compat", "")) == "recommended", str(row))
	# Global plug-ins that are NOT on the list stay out (original rule).
	_check("a list change marks the data for reload", pl.needs_reload())
	# Persistence: the state file carries the lists under tcAddOns (the Apple UserDefaults JSON is the same shape).
	var sf: String = OS.get_environment("NOVA_PLUGIN_STATE")
	if sf != "" and FileAccess.file_exists(sf):
		var st: Variant = _j(FileAccess.get_file_as_string(sf))
		_check("the lists persist in plugins-state.json under tcAddOns", st is Dictionary and (st as Dictionary).has("tcAddOns")
			and ((st as Dictionary).tcAddOns as Dictionary).has(tc))


# --- 2. parity with the shared Swift merge (novaswift-extract merged-counts) -------------------------

func _parity(enabled_ids: Array) -> void:
	var ref_path: String = OS.get_environment("NOVA_PLUGCHECK_REF")
	summary["resources"] = pl.loaded_resource_count()
	if ref_path == "" or not FileAccess.file_exists(ref_path):
		_warn("no reference JSON given -- parity skipped")
		return
	var ref = _j(FileAccess.get_file_as_string(ref_path))
	if not (ref is Dictionary):
		_check("reference JSON parses", false, ref_path)
		return
	_check("same resource total as the shared Swift merge", int(ref.total) == pl.loaded_resource_count(),
		"swift=%d godot=%d" % [int(ref.total), pl.loaded_resource_count()])
	var bad: Array = []
	for t in ref.types:
		if int(ref.types[t]) != pl.loaded_type_count(String(t)):
			bad.append("%s swift=%d godot=%d" % [t, int(ref.types[t]), pl.loaded_type_count(String(t))])
	_check("same count for all %d resource types" % (ref.types as Dictionary).size(), bad.is_empty(), str(bad))
	var ref_en: Array = ref.plugins
	ref_en.sort()
	var got: Array = enabled_ids.duplicate()
	got.sort()
	var imported: bool = OS.get_environment("NOVA_PLUGCHECK_IMPORT") != ""   # imported ids are the archive's name
	_check("same enabled bundles" if not imported else "an imported plug-in is enabled by default or as a TC",
		(ref_en == got) if not imported else (ref_en.is_empty() == got.is_empty()), "swift=%s godot=%s" % [ref_en, got])
	summary["types"] = (ref.types as Dictionary).size()


# --- 3. everything the plug-in contributes decodes ---------------------------------------------------

## Resource ids of `type` the plug-ins supply. Under a total conversion the TC's own Nova Files are the
## base layer (source ""), so everything counts.
func _contributed(type: String, lo: int, hi: int) -> Array:
	var out: Array = []
	var tc: bool = _tc_active()
	for id in range(lo, hi):
		var src: String = pl.resource_source(type, id)
		if src != "?" and (src != "" or tc):
			out.append(id)
	return out


func _tc_active() -> bool:
	for p in _j(pl.list()):
		if p.enabled and p.total_conversion:
			return true
	return false


func _asset_sweep() -> void:
	var bad: Dictionary = {}
	var n_total: int = 0
	var counts: Dictionary = {}
	var spec: Array = [
		["PICT", 128, 32768], ["cicn", 128, 32768], ["snd ", 128, 32768],
		["shïp", 128, 2048], ["spöb", 128, 2048], ["bööm", 128, 1024], ["röid", 128, 256],
	]
	for s in spec:
		var t: String = s[0]
		var ids: Array = _contributed(t, s[1], s[2])
		counts[t] = ids.size()
		n_total += ids.size()
		var failures: Array = []
		for id in ids:
			var good: bool = true
			match t:
				"PICT":
					var wh: PackedInt32Array = nova.pict_info(id)
					good = wh.size() == 2 and wh[0] > 0 and wh[1] > 0
				"cicn":
					var ci: PackedInt32Array = nova.cicn_info(id)
					good = ci.size() >= 2 and ci[0] > 0 and ci[1] > 0
				"snd ":
					var si: PackedInt32Array = nova.sound_info(id)
					good = si.size() >= 4 and si[3] > 0
				"shïp":
					good = nova.sprite_info(Sprites.SHIP, id).size() >= 7
				"spöb":
					good = nova.sprite_info(Sprites.SPOB, id).size() >= 7
				"bööm":
					good = nova.sprite_info(Sprites.BOOM, id).size() >= 7
				"röid":
					good = nova.sprite_info(Sprites.ASTEROID, id).size() >= 7
			if not good:
				if t == "shïp" and pl.resource_source("shän", id) == "?":
					_warn("shïp %d has no shän resource (data quirk: no graphic in any frontend)" % id)
					continue
				if t == "röid" and pl.resource_source("spïn", id + 672) == "?":
					_warn("röid %d has no spïn %d (data quirk: rock type without art)" % [id, id + 672])
					continue
				failures.append(id)
		if not failures.is_empty():
			bad[t] = failures
	# shän layers: engine / shield / lights / weapon / alt overlays of every hull the plug-ins define
	var layer_counts: Dictionary = {"shield": 0, "engine": 0, "lights": 0, "weapon": 0, "alt": 0}
	var shan_ids: Array = _contributed("shän", 128, 2048)
	for id in shan_ids:
		if nova.sprite_info(Sprites.SHIELD, id).size() >= 7:
			layer_counts["shield"] += 1
		if nova.sprite_info(Sprites.ENGINE_GLOW, id).size() >= 7:
			layer_counts["engine"] += 1
		if nova.sprite_info(Sprites.LIGHTS, id).size() >= 7:
			layer_counts["lights"] += 1
		if nova.sprite_info(Sprites.WEAPON_GLOW, id).size() >= 7:
			layer_counts["weapon"] += 1
		if nova.sprite_info(Sprites.ALT, id).size() >= 7:
			layer_counts["alt"] += 1
	counts["shän"] = shan_ids.size()
	summary["shan_layers"] = layer_counts
	print("   shän overlay layers that decode: ", layer_counts)
	var rle_contrib: int = _contributed("rlëD", 128, 32768).size()
	counts["rlëD"] = rle_contrib
	print("   plug-in contributed assets: ", counts)
	summary["contrib"] = n_total
	# base-game parity: how many of the same kind fail to decode with NO plug-in is measured by the script's
	# BASE run; here any failing plug-in resource is a real problem unless it is also undecodable in the original.
	for t in bad:
		var ids: Array = bad[t]
		_check("every contributed %s decodes" % t, false, "%d undecodable, e.g. %s" % [ids.size(), ids.slice(0, 12)])
	if bad.is_empty():
		_check("every contributed PICT / cicn / snd / ship / stellar / boom / rock sprite decodes", true, "%d resources" % n_total)


# --- 4. music + movies are found in the plug-in folders ----------------------------------------------

func _media_search(list: Array) -> void:
	var roots: PackedStringArray = _j(pl.media_dirs())
	summary["media_dirs"] = roots.size()
	print("   media search order: ", roots)
	var music_name: String = str(nova.title_music_name())
	var found: String = TitleMusic.locate_in(roots, music_name)
	print("   title music '", music_name, "' ->", found if found != "" else " (none)")
	# Wherever the plug-in ships a file of that name the search must pick the highest-priority copy.
	for r in roots:
		var direct: String = ""
		for ext in ["", ".mov", ".mp3"]:
			if FileAccess.file_exists(String(r).path_join(music_name + ext)):
				direct = String(r).path_join(music_name + ext)
				break
		if direct != "":
			_check("title music resolves to the first search root that has it", found == direct, "%s vs %s" % [found, direct])
			break
	# every .mov that a dësc names must be locatable
	var missing: Array = []
	var named: int = 0
	for id in range(128, 32768):
		if pl.resource_source("dësc", id) == "?":
			continue
		var dm = _j(pl.desc_movie(id))
		var m: String = str(dm.movie).strip_edges() if dm is Dictionary else ""
		if m == "" or (pl.resource_source("dësc", id) == "" and not _tc_active()):
			continue   # base-game movies are the user's own install's business
		named += 1
		if Movies.find_movie(m, roots) == "":
			missing.append("%d:%s" % [id, m])
	summary["desc_movies"] = named
	await _media_parity(roots)
	await _offer_movie_chain()
	if named > 0:
		if missing.is_empty():
			_check("every dësc movie file is found (%d)" % named, true)
		else:
			_warn("dësc movies not shipped with this install", str(missing.slice(0, 8)))


## NOVA_PLUGCHECK_MEDIA (novaswift-extract desc-movies): Godot resolves the same movie files as the shared Swift code
## (so the Apple app finds them too), each found clip is playable (converts through ffmpeg: .mov, .mp4, .gif), the
## plug-in's / conversion's font files are the same, and the data's font name resolves to the shipped font.
func _media_parity(roots: PackedStringArray) -> void:
	var path: String = OS.get_environment("NOVA_PLUGCHECK_MEDIA")
	var imported_zip: bool = OS.get_environment("NOVA_PLUGCHECK_IMPORT").ends_with(".zip")
	if path == "" or not FileAccess.file_exists(path):
		if imported_zip:
			await _imported_media_check()
		return
	var ref: Variant = _j(FileAccess.get_file_as_string(path))
	if not (ref is Dictionary):
		_check("media reference JSON parses", false, path)
		return
	var movies: Array = (ref as Dictionary).get("movies", [])
	var bad: Array = []
	var unplayable: Array = []
	var found_n: int = 0
	var sample_played: Dictionary = {}
	Prefs.set_value("classic", "play_movies", true)
	Movies.cache_root = work.path_join("movies")
	for m in movies:
		var name: String = str(m.movie).strip_edges()
		var godot_path: String = str(pl.find_media(name))
		var swift_found: bool = bool(m.found)
		if swift_found != (godot_path != ""):
			bad.append("%d:%s swift=%s godot=%s" % [int(m.id), name, swift_found, godot_path != ""])
		if swift_found and godot_path != "" and godot_path.get_file().nocasecmp_to(str(m.path).get_file()) != 0:
			bad.append("%d:%s different file %s vs %s" % [int(m.id), name, godot_path.get_file(), str(m.path).get_file()])
		if godot_path != "":
			found_n += 1
			if Movies.available() and not sample_played.has(name):
				sample_played[name] = true
				var info: Dictionary = Movies.transcode(godot_path)
				if info.is_empty():
					unplayable.append(name)
				else:
					# DescMovie.lookup is what every text dialog calls.
					var clip: Dictionary = DescMovie.lookup(int(m.id))
					if clip.is_empty():
						unplayable.append("%s (lookup)" % name)
	summary["media_movies"] = "%d/%d" % [found_n, movies.size()]
	if not movies.is_empty():
		_check("Godot resolves the same %d dësc movie files as the shared Swift code (%d found)" % [movies.size(), found_n], bad.is_empty(), str(bad.slice(0, 6)))
		if Movies.available():
			_check("every found movie converts and is ready to play (%d distinct clips, mov/mp4/gif)" % sample_played.size(), unplayable.is_empty(), str(unplayable))
		else:
			_warn("ffmpeg not installed: dësc movies are skipped (as with QuickTime Movies off)")
	# Fonts the conversion ships next to its data.
	var swift_fonts: Array = (ref as Dictionary).get("fontFiles", [])
	var godot_fonts: Array = _j(pl.font_files())
	var sf: Array = swift_fonts.map(func(p): return str(p).get_file())
	var gf: Array = godot_fonts.map(func(p): return str(p).get_file())
	sf.sort()
	gf.sort()
	_check("the conversion's font files match the shared Swift resolution (%s)" % str(gf), sf == gf, "swift=%s godot=%s" % [sf, gf])
	ClassicTheme.setup(nova)
	for fname in (ref as Dictionary).get("fontNames", []):
		var shipped: bool = false
		for f in gf:
			if str(f).get_basename().to_lower() in str(fname).to_lower() or str(fname).to_lower() in str(f).to_lower():
				shipped = true
		if shipped:
			var font: Font = ClassicTheme.font_for(str(fname))
			_check("the data's font '%s' resolves to the shipped font file, not the Arimo substitute" % fname,
				font != null and font != ClassicTheme.ARIMO and font != ClassicTheme.RUBIK)


## An imported zip: every movie the loaded data names for its plug-in is found, i.e. the import extracted the
## media that only ever lived inside the archive (ARPIA2's gasminer.mov / credits.mov).
func _imported_media_check() -> void:
	var missing: Array = []
	var named: int = 0
	for id in range(128, 32768):
		if str(pl.resource_source("dësc", id)) in ["?", ""]:
			continue
		var dm: Variant = _j(pl.desc_movie(id))
		var m: String = str((dm as Dictionary).movie).strip_edges() if dm is Dictionary else ""
		if m == "":
			continue
		named += 1
		if str(pl.find_media(m)) == "":
			missing.append("%d:%s" % [id, m])
	if named > 0:
		_check("the import extracted every media file the zip's dësc records name (%d)" % named, missing.is_empty(), str(missing))


# --- 5. the pilot flow --------------------------------------------------------------------------------

func _flow() -> void:
	var scen: Array = _j(nova.pilot_scenarios())
	_check("the data offers chär start scenarios", scen.size() > 0, "%d" % scen.size())
	summary["scenarios"] = scen.size()
	if scen.is_empty():
		return
	var pilots: String = OS.get_environment("NOVA_PILOTS_DIR")
	if pilots == "":
		pilots = work + "/Pilots"
	var all: bool = OS.get_environment("NOVA_PLUGCHECK_ALL") == "1"
	var smoke_failed: Array = []
	for i in scen.size():
		var sc: Dictionary = scen[i]
		if i == 0 or all:
			continue
		# quick smoke for the other starts: the pilot builds, the world builds, the first frames run
		var pid: String = nova.pilot_create(pilots, int(sc.id), "Smoke %d" % i, true, "", "")
		if pid == "" or not nova.make_world(-1):
			smoke_failed.append(str(sc.name))
			continue
		for k in 6:
			nova.step(1.0 / 30.0)
		nova.pilot_delete(pilots, pid)
	if scen.size() > 1 and not all:
		_check("the other %d start scenarios build a pilot + world" % (scen.size() - 1), smoke_failed.is_empty(), str(smoke_failed))
	for i in scen.size():
		if i > 0 and not all:
			break
		await _scenario_flow(pilots, scen[i])


func _scenario_flow(pilots: String, sc: Dictionary) -> void:
	print("-- scenario '%s' (ship %s, %d cr)" % [sc.name, sc.ship, int(sc.cash)])
	var pid: String = nova.pilot_create(pilots, int(sc.id), "Plug Tester", true, "", "")
	if not _check("new pilot in this scenario", pid != ""):
		return
	if not _check("make_world", nova.make_world(-1)):
		return
	dbg.console_run("god on")   # a stray pirate must not end the smoke run; the harness checks loading, not combat
	if audio == null:
		audio = GameAudio.new()
		root.add_child(audio)
		audio.setup(nova)
	if rend != null:
		rend.get_parent().queue_free()
	var holder := Node2D.new()
	root.add_child(holder)
	rend = Renderer.new()
	holder.add_child(rend)
	rend.has_data = true
	rend.setup(nova)
	rend.reset_world()
	for i in 4:
		_step()
		audio.apply(nova.drain_sound_cues())
		rend.frame(1.0 / 30.0, 0.0, true)
	_check("player ship exists with a graphic", nova.sprite_info(Sprites.SHIP, int(nova.player_ship_type())).size() >= 7,
		"shïp %d" % int(nova.player_ship_type()))
	if nova.is_landed():
		_check("take off", nova.launch())
	await _frames(1)

	# land for real: the launch put us beside the stellar
	var landed: bool = nova.attempt_land()
	if not landed:
		landed = await _land_somewhere()
	_check("landed at a spaceport", landed)
	if landed:
		await _services(pilots)
		_check("launch from the spaceport", nova.launch())
	await _frames(1)

	# flight: thrust, turn, fire, a few seconds, then draw
	for i in 90:
		nova.set_intent(i % 40 < 15, false, true, false, false, i < 30 and i % 10 == 0, false)
		_step()
		nova.drain_events()
		nova.drain_effects()
		audio.apply(nova.drain_sound_cues())
		rend.frame(1.0 / 30.0, 0.0, true)
	nova.set_intent(false, false, false, false, false, false, false)
	await _frames(2)
	var ship_misses: Array = []
	var other_misses: Array = []
	for k in rend.sprites.misses:
		var key: Vector2i = k
		if key.x in [Sprites.SHIP, Sprites.SPOB, Sprites.ASTEROID, Sprites.STARFIELD]:
			ship_misses.append("%d/%d" % [key.x, key.y])
		else:
			other_misses.append("%d/%d" % [key.x, key.y])
	_check("flight frames drew with no missing hull / stellar / rock / starfield graphic", ship_misses.is_empty(), str(ship_misses))
	if not other_misses.is_empty():
		print("   info optional layers/art absent (normal for hulls without them): ", other_misses.size(), " e.g. ", other_misses.slice(0, 6))
	_check("no sound cue went unplayable", audio.missing_sounds.is_empty(), str(audio.missing_sounds.keys()))

	await _map_and_jump()
	for i in 20:
		_step()
		audio.apply(nova.drain_sound_cues())
		rend.frame(1.0 / 30.0, 0.0, true)
	_check("player alive and flying after the jump", nova.player_is_alive())
	var post: Array = []
	for k in rend.sprites.misses:
		var key3: Vector2i = k
		if key3.x in [Sprites.SHIP, Sprites.SPOB, Sprites.ASTEROID, Sprites.STARFIELD]:
			post.append("%d/%d" % [key3.x, key3.y])
	_check("no missing hull / stellar graphic after the jump either", post.is_empty(), str(post))
	_check("no unplayable sound after the jump", audio.missing_sounds.is_empty(), str(audio.missing_sounds.keys()))
	rend.get_parent().queue_free()
	rend = null
	nova.pilot_delete(pilots, pid)


func _land_somewhere() -> bool:
	for t in 4000:
		if nova.can_land_now():
			return nova.attempt_land()
		var xf: PackedFloat32Array = nova.body_transforms()
		var p: Vector2 = nova.player_position()
		var best: int = -1
		var bd: float = INF
		for i in range(0, xf.size(), 4):
			if int(xf[i + 3]) != 0:
				continue
			var d: float = p.distance_to(Vector2(xf[i], xf[i + 1]))
			if d < bd:
				bd = d
				best = i
		if best < 0:
			return false
		var tgt: Vector2 = Vector2(xf[best], xf[best + 1])
		var dir: Vector2 = tgt - p
		var v: Vector2 = nova.player_velocity()
		var thrust: bool = false
		if v.length() > 95.0:
			thrust = absf(angle_difference(nova.player_angle(), atan2(-v.x, -v.y))) < 0.35
		else:
			thrust = v.length() < 90.0 and dir.length() > float(xf[best + 2]) + 90.0 \
				and absf(angle_difference(nova.player_angle(), atan2(dir.x, dir.y))) < 0.35
		nova.set_intent(false, false, thrust, false, false, false, false)
		nova.set_aim_heading(true, atan2(-v.x, -v.y) if v.length() > 95.0 else atan2(dir.x, dir.y))
		_step()
		if t % 4 == 0:
			rend.frame(1.0 / 30.0, 0.0, true)
		if t % 8 == 0:
			await process_frame
	return false


func _services(pilots: String) -> void:
	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	nova.debug_set_credits(500000)
	sp.open()
	if nova.offer_pending():
		nova.offer_decline()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	await _frames(2)
	var info: Dictionary = _j(nova.spaceport_info())
	print("   landed at ", info.name, ": trade=", info.trade, " outfitter=", info.outfitter, " shipyard=", info.shipyard, " bar=", info.get("bar", false))
	_check("landing description present", str(info.description) != "" or str(info.name) != "")
	# The starting stellar rarely has every service: hop through docked stellars until each one has been opened.
	var seen: Dictionary = {}
	var order: Array = range(128, 1700)
	var landed_spob: int = int(nova.landed_spob_id())
	order.push_front(landed_spob)
	for id in order:
		if seen.size() >= 5:
			break
		if id != landed_spob and not nova.debug_dock_at(id):
			continue
		var inf: Dictionary = _j(nova.spaceport_info())
		if inf.get("trade", false) and not seen.has("trade") and not (_j(nova.trade_view()).rows as Array).is_empty():
			sp.open()
			sp._show_trade()
			await _frames(1)
			seen["trade"] = id
			sp._show_hub()
		if inf.get("outfitter", false) and not seen.has("outfitter") and not (_j(nova.outfitter_list()) as Array).is_empty():
			sp.open()
			sp._show_outfitter()
			await _frames(1)
			seen["outfitter"] = id
			sp._show_hub()
		if inf.get("shipyard", false) and not seen.has("shipyard") and not (_j(nova.shipyard_list()) as Array).is_empty():
			sp.open()
			sp._show_shipyard()
			await _frames(1)
			seen["shipyard"] = id
			sp._show_hub()
		if inf.get("bar", false) and not seen.has("bar"):
			sp.open()
			sp._show_bar()
			await _frames(1)
			seen["bar"] = id
			sp._show_hub()
		if not seen.has("bbs"):
			sp.open()
			sp._open_bbs()
			await _frames(1)
			seen["bbs"] = id
			sp._show_hub()
		while nova.story_text_pending():
			nova.story_text_dismiss()
		if nova.offer_pending():
			nova.offer_decline()
	for s in ["trade", "outfitter", "shipyard", "bar", "bbs"]:
		if seen.has(s):
			print("   opened ", s, " at spöb ", seen[s])
		else:
			_warn("no stellar in this data offers the %s service" % s)
	_check("at least the outfitter, shipyard and trade center opened somewhere",
		seen.has("trade") and seen.has("outfitter") and seen.has("shipyard"), str(seen.keys()))
	# the stellar picture each service shows
	var pics: int = 0
	var info2: Dictionary = _j(nova.spaceport_info())
	var lp: int = nova.spaceport_picture_id(1, int(info2.get("id", -1)))
	if lp >= 0:
		var wh: PackedInt32Array = nova.pict_info(lp)
		_check("landing PICT decodes", wh.size() == 2, "PICT %d" % lp)
		pics += 1
	sp.close()
	sp.queue_free()
	await _frames(1)
	# leave whichever stellar the hop ended on by relaunching in the caller; re-seat into the starting system state
	nova.debug_dock_at(landed_spob)


func _map_and_jump() -> void:
	var gm = GalaxyMap.new()
	root.add_child(gm)
	gm.setup(nova)
	nova.nav_refresh()
	gm.open()
	await _frames(2)
	_check("galaxy map opens and is visible", gm.is_open())
	var stride: int = int(nova.nav_stride())
	var systems: PackedFloat32Array = nova.nav_systems()
	_check("map shows known systems", systems.size() >= stride and stride > 0, "%d systems" % (systems.size() / maxi(stride, 1)))
	var start: int = nova.nav_current_system()
	var links: PackedInt32Array = nova.nav_links()
	var dest: int = -1
	for i in range(0, links.size(), 2):
		if links[i] == start:
			dest = links[i + 1]
			break
		if links[i + 1] == start:
			dest = links[i]
			break
	gm.close() if gm.has_method("close") else gm.set_visible(false)
	gm.queue_free()
	if dest == -1:
		_warn("this start has no hyperlink from its system (a self-contained scenario) -- jump skipped")
		return
	nova.nav_click(dest)
	var tries: int = 0
	while tries < 3000:
		nova.set_intent(false, false, true, false, false, false, false)
		_step()
		tries += 1
		if tries % 15 == 0:
			nova.begin_hyperjump()
			if nova.hyperjump_active():
				break
	var ticks: int = 0
	while nova.hyperjump_active() and ticks < 6000:
		nova.set_intent(false, false, false, false, false, false, false)
		_step()
		audio.apply(nova.drain_sound_cues())
		ticks += 1
	if tries >= 3000 or not nova.player_is_alive():
		print("   jump diagnostics: alive=%s fuel=%.2f jumps=%s tries=%d armed route=%s" % [nova.player_is_alive(), nova.player_fuel_fraction(), nova.player_jumps_remaining(), tries, nova.nav_route_armed()])
	_check("hyperjump completes into the next system", nova.take_jump_arrival() != "" and nova.nav_current_system() == dest,
		"now in %d, wanted %d" % [nova.nav_current_system(), dest])


## A mission whose offer dësc names a movie: StoryScreens finds it in the plug-in folders, converts it (ffmpeg)
## and reports it ready -- the chain the offer dialog uses.
func _offer_movie_chain() -> void:
	var ss = StoryScreens.new()
	root.add_child(ss)
	ss.setup(nova)
	var mid: int = -1
	var clip: String = ""
	for id in range(128, 2048):
		if pl.resource_source("mïsn", id) == "?":
			continue
		var dm = _j(pl.desc_movie(3872 + id))
		if dm is Dictionary and str(dm.movie).strip_edges() != "":
			var f: String = Movies.find_movie(str(dm.movie).strip_edges(), Movies.search_roots(""))
			if f != "":
				mid = id
				clip = f
				break
	if mid < 0:
		print("   (no mission offer in this data names a movie)")
		ss.queue_free()
		return
	Prefs.set_value("classic", "play_movies", true)
	summary["offer_movie"] = clip.get_file()
	if not Movies.available():
		_warn("ffmpeg not installed: mission %d's movie '%s' is skipped (as with QuickTime Movies off)" % [mid, clip.get_file()])
		ss.queue_free()
		return
	Movies.cache_root = work.path_join("movies")
	ss._offer_movie(mid)   # starts the background conversion
	Movies.wait(clip)
	var mv: Dictionary = ss._offer_movie(mid)
	_check("mission %d's offer movie '%s' converts and is ready to play" % [mid, clip.get_file()], not mv.is_empty())
	ss.queue_free()


func _step() -> void:
	dbg.frame_tick(false)
	nova.step(1.0 / 30.0)

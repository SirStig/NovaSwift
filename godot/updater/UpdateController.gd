# NOVA Swift updater -- the in-game side: schedules the check, shows the prompt, downloads, verifies, stages and
# hands over to updater mode. A Node owned by Shell (group "nova_updater"; Settings calls check_now()).
#
#   Shell._open_main_menu -> on_main_menu_shown()   housekeeping once, then an automatic check (<= once / 24 h)
#   Settings "Check now"  -> check_now()            manual check, always answers (up to date / offer / error)
#
# Nothing is downloaded until the player presses Update Now. See docs/UPDATER.md for the whole flow.
# Loaded with preload() (no class_name).
extends Node

const Prefs = preload("res://Prefs.gd")
const UpdateConfig = preload("res://updater/UpdateConfig.gd")
const UpdateChecker = preload("res://updater/UpdateChecker.gd")
const UpdateHttp = preload("res://updater/UpdateHttp.gd")
const UpdateManifest = preload("res://updater/UpdateManifest.gd")
const UpdateInstall = preload("res://updater/UpdateInstall.gd")
const UpdaterMode = preload("res://updater/UpdaterMode.gd")
const Semver = preload("res://updater/Semver.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")

var shell: Node
var _http: Node
var _busy: bool = false
var _housekept: bool = false
var _pending: Dictionary = {}       # the release on offer
var _offered: bool = false
var _layer: CanvasLayer
var _tok: Dictionary = {}
var _under: Node
var _status_label: Label
var _bar: ProgressBar
var _cancelled: bool = false
var _handing_off: bool = false


func setup(owner_shell: Node) -> void:
	shell = owner_shell
	add_to_group("nova_updater")
	_http = UpdateHttp.new()
	add_child(_http)
	_http.progress.connect(_on_download_progress)


# --- entry points -------------------------------------------------------------------------------

## The main menu just opened (Shell). Housekeeping runs once per process; the automatic check at most daily.
func on_main_menu_shown() -> void:
	if not _housekept:
		_housekept = true
		_housekeeping()
	if _busy or _layer != null:
		return
	if not _pending.is_empty() and not _offered:
		_offer(_pending)
		return
	if not bool(Prefs.get_value("updates", "check")) or UpdateConfig.check_blocker() != "":
		return
	var now: int = UpdateConfig.now()
	if now - int(Prefs.get_value("updates", "last_check")) < UpdateConfig.CHECK_INTERVAL_SEC:
		return
	if now - int(Prefs.get_value("updates", "last_attempt")) < UpdateConfig.RETRY_INTERVAL_SEC:
		return
	await _run_check(false)


## Settings > Support > Updates > Check now.
func check_now() -> void:
	if _busy or _layer != null:
		return
	var why: String = UpdateConfig.check_blocker()
	if why != "":
		Alert.show(self, {"title": "Updates unavailable", "message": why})
		return
	await _run_check(true)


## Human text for Settings: when the last successful check was.
static func last_check_text() -> String:
	var t: int = int(Prefs.get_value("updates", "last_check"))
	if t <= 0:
		return "never"
	return Time.get_datetime_string_from_unix_time(t, true) + " UTC"


## Why the player will not see automatic updates (for a Settings caption), or "".
static func disabled_reason() -> String:
	return UpdateConfig.check_blocker()


# --- the check ----------------------------------------------------------------------------------

func _run_check(manual: bool) -> void:
	_busy = true
	Prefs.set_value("updates", "last_attempt", UpdateConfig.now())
	Prefs.save()
	_http.reset()
	var need_assets: bool = OS.get_name() == "Linux" or OS.get_name() == "Windows"
	var r: Dictionary = await _http.get_bytes(UpdateConfig.API_RELEASES, "application/vnd.github+json", 2097152)
	_busy = false
	var json: Variant = null
	if bool(r.get("ok", false)):
		json = JSON.parse_string((r["body"] as PackedByteArray).get_string_from_utf8())
	if not (json is Array):
		# Offline / rate-limited (403) / 5xx / malformed: silent for the automatic check, retried later.
		if manual:
			Alert.show(self, {"title": "Couldn't check for updates",
				"message": str(r.get("error", "")) if not bool(r.get("ok", false)) else "The update server sent an unexpected answer. Try again later."})
		return
	Prefs.set_value("updates", "last_check", UpdateConfig.now())
	Prefs.save()
	var exp_on: bool = bool(Prefs.get_value("updates", "beta"))
	var cur: String = UpdateConfig.current_version()
	var rel: Dictionary = {}
	for cand in UpdateChecker.candidates(json, cur, exp_on, need_assets).slice(0, 3):
		var c: Dictionary = await _resolve_channel(cand)
		if bool(c.get("ok", false)) and (exp_on or str(cand["channel"]) != "experimental"):
			rel = cand
			break
	if rel.is_empty() and not exp_on and running_experimental():
		# Experimental updates were turned off while on an experimental build: offer the way back (the ONLY
		# downgrade, and only if the player chooses it). The signed manifest must say "stable".
		var st: Dictionary = UpdateChecker.newest_stable(json, need_assets)
		if not st.is_empty() and Semver.compare(str(st["version"]), cur) != 0:
			var c2: Dictionary = await _resolve_channel(st)
			if bool(c2.get("ok", false)) and str(st["channel"]) == "stable":
				st["downgrade"] = true
				rel = st
	if rel.is_empty():
		if manual:
			Alert.show(self, {"title": "You're up to date", "message": "NovaSwift %s is the newest version%s." % [
				cur, " on the experimental channel" if exp_on else ""]})
		return
	if not manual and str(Prefs.get_value("updates", "skipped")) == str(rel["version"]):
		return
	_pending = rel
	_offered = false
	if shell == null or shell.main_menu == null:
		# In flight (Settings from the pause menu): installing means leaving the game -- do it from the menu.
		_offered = false
		Alert.show(self, {"title": "Update available", "message": "NovaSwift %s is available. Return to the main menu to install it." % rel["version"]})
		return
	_offer(rel)


## Is the running build experimental? (a pre-release version, or installed from an experimental manifest)
static func running_experimental() -> bool:
	return Semver.is_prerelease(UpdateConfig.current_version()) or str(Prefs.get_value("updates", "installed_channel")) == "experimental"


## Download + verify the release's signed manifest and set rel["channel"] from it (the signed label wins over the
## GitHub flag / tag, so editing the release cannot relabel a build). Caches rel["manifest"]. {ok, error}.
func _resolve_channel(rel: Dictionary) -> Dictionary:
	if rel.has("manifest"):
		return {"ok": true}
	var assets: Dictionary = rel["assets"]
	if not (assets.has(UpdateConfig.MANIFEST_ASSET) and assets.has(UpdateConfig.SIGNATURE_ASSET)):
		return {"ok": true}       # macOS: download-page only, nothing to verify; the flag / tag label stands
	var pem: String = UpdateConfig.pubkey_pem()
	if pem == "":
		return {"ok": false, "error": "This build cannot verify updates (no signing key)."}
	var mr: Dictionary = await _http.get_bytes(str(assets[UpdateConfig.MANIFEST_ASSET]), "application/octet-stream", UpdateManifest.MAX_MANIFEST_BYTES)
	var sr: Dictionary = await _http.get_bytes(str(assets[UpdateConfig.SIGNATURE_ASSET]), "application/octet-stream", 4096)
	if _cancelled:
		return {"ok": false, "cancelled": true}
	if not bool(mr.get("ok", false)) or not bool(sr.get("ok", false)):
		return {"ok": false, "error": "Could not download the update information. " + str(mr.get("error", sr.get("error", "")))}
	var mbytes: PackedByteArray = mr["body"]
	if not UpdateManifest.verify_signature(mbytes, sr["body"], pem):
		return {"ok": false, "error": "The update's signature could not be verified, so it was NOT installed."}
	var pm: Dictionary = UpdateManifest.parse(mbytes)
	if not bool(pm["ok"]):
		return {"ok": false, "error": str(pm["error"])}
	var manifest: Dictionary = pm["manifest"]
	if str(manifest["version"]) != str(rel["version"]):
		return {"ok": false, "error": "The signed update information does not match this release, so it was rejected."}
	rel["manifest"] = manifest
	rel["channel"] = UpdateManifest.channel_of(manifest, str(rel["channel"]))
	rel["prerelease"] = str(rel["channel"]) == "experimental"
	return {"ok": true}


# --- dialogs ------------------------------------------------------------------------------------

func _begin_overlay() -> void:
	if not _tok.is_empty():
		return
	_under = shell.settings if (shell.settings != null) else shell.main_menu
	if _under != null:
		_tok = shell._overlay_push(_under)
	else:
		_tok = {"none": true}


func _end_overlay() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_status_label = null
	_bar = null
	if not _tok.is_empty():
		if _under != null and is_instance_valid(_under):
			shell._overlay_pop(_tok, _under)
		_tok = {}
	_under = null


## Replace the dialog on screen (keeps the inert hold on the screen beneath).
func _show(opts: Dictionary) -> Dictionary:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_begin_overlay()
	_layer = CanvasLayer.new()
	_layer.layer = 210
	_layer.name = "UpdateDialog"
	add_child(_layer)
	return Chrome.dialog(_layer, opts)


func _offer(rel: Dictionary) -> void:
	_offered = true
	_pending = rel
	var blocker: String = UpdateConfig.install_blocker()
	var can_install: bool = blocker == ""
	var downgrade: bool = bool(rel.get("downgrade", false))
	var experimental: bool = str(rel.get("channel", "stable")) == "experimental"
	var title: String = "Update available"
	if downgrade:
		title = "Return to stable version"
	elif experimental:
		title = "Experimental update available"
	var go_text: String = "Return to Stable" if downgrade else "Update Now"
	var specs: Array = [
		{"text": "Skip This Version", "cb": func() -> void:
			Prefs.set_value("updates", "skipped", str(rel["version"]))
			Prefs.save()
			_end_overlay()},
		{"text": "Later" if not downgrade else "Stay on This Build", "cancel": true, "cb": func() -> void: _end_overlay()},
	]
	if can_install:
		specs.append({"text": go_text, "default": true, "cb": func() -> void: _install()})
	else:
		specs.append({"text": "Open Download Page", "default": true, "cb": func() -> void:
			OS.shell_open(str(rel["html_url"]))
			_end_overlay()})
	var d: Dictionary = _show({"title": title, "width": 560.0, "buttons": specs})
	var body: VBoxContainer = d["body"]
	if experimental:
		NC.badge(body, "Experimental build \u2014 may be unstable", T.RED)
	if downgrade:
		NC.label(body, "You are on the experimental build %s. NovaSwift %s is the newest stable version." % [UpdateConfig.current_version(), rel["version"]], "body", "regular", T.WHITE, true)
		NC.label(body, "This goes BACK to an older version. Pilots saved by the newer build may not load in it. Back up your pilots first.", "body", "bold", T.RED, true)
	else:
		NC.label(body, "NovaSwift %s is ready. You have %s." % [rel["version"], UpdateConfig.current_version()], "body", "regular", T.WHITE, true)
	var scroll: ScrollContainer = _NotesScroll.new()
	scroll.custom_minimum_size = Vector2(0, 180)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	var notes_box: VBoxContainer = VBoxContainer.new()
	notes_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(notes_box)
	NC.label(notes_box, UpdateChecker.clean_notes(str(rel["body"])), "caption", "regular", T.SECONDARY, true)
	if not can_install:
		NC.caption(body, blocker + " Open the download page to get the new version.")
	elif experimental:
		NC.caption(body, "Test builds can break saves. Back up your pilots first. Your settings are not touched.")
	else:
		NC.caption(body, "NovaSwift will download the update, verify it, and restart. Your pilots and settings are not touched.")


## Release-notes scroller that a gamepad can focus and scroll with up / down (and lets focus go on at the ends).
class _NotesScroll extends ScrollContainer:
	func _init() -> void:
		focus_mode = Control.FOCUS_ALL

	func _gui_input(event: InputEvent) -> void:
		var bar: ScrollBar = get_v_scroll_bar()
		var max_scroll: int = int(bar.max_value - bar.page)
		if event.is_action_pressed("ui_down") and scroll_vertical < max_scroll:
			scroll_vertical = mini(max_scroll, scroll_vertical + 48)
			accept_event()
		elif event.is_action_pressed("ui_up") and scroll_vertical > 0:
			scroll_vertical = maxi(0, scroll_vertical - 48)
			accept_event()
		elif event.is_action_pressed("ui_page_down"):
			scroll_vertical = mini(max_scroll, scroll_vertical + 160)
			accept_event()
		elif event.is_action_pressed("ui_page_up"):
			scroll_vertical = maxi(0, scroll_vertical - 160)
			accept_event()


func _show_progress(text: String, fraction: float, cancellable: bool = true) -> void:
	var specs: Array = []
	if cancellable:
		specs.append({"text": "Cancel", "cancel": true, "cb": func() -> void: _cancel_install()})
	var d: Dictionary = _show({"title": "Updating NovaSwift", "width": 520.0, "buttons": specs})
	var body: VBoxContainer = d["body"]
	_status_label = NC.label(body, text, "body", "regular", T.WHITE, true)
	_bar = NC.progress(body, maxf(0.0, fraction), 440.0)
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _set_progress(text: String, fraction: float) -> void:
	if _status_label != null and is_instance_valid(_status_label):
		_status_label.text = text
	if _bar != null and is_instance_valid(_bar):
		_bar.value = clampf(fraction, 0.0, 1.0)


func _on_download_progress(done: int, total: int) -> void:
	var mb: float = 1048576.0
	if total > 0:
		_set_progress("Downloading... %.1f of %.1f MB" % [done / mb, total / mb], float(done) / float(total))
	else:
		_set_progress("Downloading... %.1f MB" % (done / mb), 0.0)


func _show_failure(message: String, page: String = "") -> void:
	var url: String = page if page != "" else str(_pending.get("html_url", UpdateConfig.RELEASES_PAGE))
	var specs: Array = [
		{"text": "Close", "cancel": true, "cb": func() -> void: _end_overlay()},
		{"text": "Open Download Page", "default": true, "cb": func() -> void:
			OS.shell_open(url)
			_end_overlay()},
	]
	var d: Dictionary = _show({"title": "Update not installed", "width": 520.0, "buttons": specs})
	NC.label(d["body"] as Node, message, "body", "regular", T.WHITE, true)
	NC.caption(d["body"] as Node, "Nothing was changed. You can keep playing this version.")


# --- the install --------------------------------------------------------------------------------

func _cancel_install() -> void:
	_cancelled = true
	_http.cancel()
	if not _handing_off:
		_end_overlay()


func _threaded(fn: Callable) -> Variant:
	var t: Thread = Thread.new()
	t.start(fn)
	while t.is_alive():
		await get_tree().process_frame
	return t.wait_to_finish()


func _aborted() -> bool:
	if _cancelled:
		_cancelled = false
		return true
	return false


func _install() -> void:
	var rel: Dictionary = _pending
	_cancelled = false
	_handing_off = false
	_busy = true
	_http.reset()
	_show_progress("Checking the update...", 0.0)
	var result: Dictionary = await _stage(rel)
	_busy = false
	if bool(result.get("cancelled", false)) or _aborted():
		return
	if not bool(result.get("ok", false)):
		_show_failure(str(result.get("error", "The update could not be prepared.")))
		return
	_handing_off = true
	_set_progress("Restarting to install...", 1.0)
	Prefs.save()
	await get_tree().create_timer(0.4).timeout
	get_tree().quit()


## Download + verify + extract + start updater mode. {ok, error, cancelled}; ok means the updater is running.
func _stage(rel: Dictionary) -> Dictionary:
	var assets: Dictionary = rel["assets"]
	var pem: String = UpdateConfig.pubkey_pem()
	if pem == "":
		return {"ok": false, "error": "This build cannot verify updates (no signing key)."}
	# 1. the signed manifest (already verified when the channel was resolved before the prompt)
	var downgrade: bool = bool(rel.get("downgrade", false))
	var res: Dictionary = await _resolve_channel(rel)
	if bool(res.get("cancelled", false)) or _cancelled:
		return {"ok": false, "cancelled": true}
	if not bool(res.get("ok", false)):
		return {"ok": false, "error": str(res.get("error", ""))}
	if not rel.has("manifest"):
		return {"ok": false, "error": "This release has no signed update information."}
	var manifest: Dictionary = rel["manifest"]
	var channel: String = str(rel["channel"])
	if channel == "experimental" and not bool(Prefs.get_value("updates", "beta")):
		return {"ok": false, "error": "This is an experimental build and Experimental updates is off."}
	if downgrade:
		if channel != "stable" or Semver.is_prerelease(str(manifest["version"])):
			return {"ok": false, "error": "Only a stable version can be returned to."}
	elif not Semver.is_newer(str(manifest["version"]), UpdateConfig.current_version()):
		return {"ok": false, "error": "The signed update is not newer than your version, so it was rejected."}
	if int(manifest.get("min_updater", 1)) > UpdateConfig.UPDATER_VERSION:
		return {"ok": false, "error": "This update needs a newer updater than your version has. Please download it from the website once."}
	var entry: Dictionary = UpdateManifest.platform_entry(manifest, UpdateConfig.platform_key())
	if entry.is_empty():
		return {"ok": false, "error": "This release has no build for your system (%s)." % UpdateConfig.platform_key()}
	if not assets.has(str(entry["asset"])):
		return {"ok": false, "error": "The release is missing its %s file." % entry["asset"]}
	# 2. room to work
	var user_dir: String = ProjectSettings.globalize_path("user://update")
	DirAccess.make_dir_recursive_absolute(user_dir)
	var install: String = UpdateConfig.install_dir()
	var size: int = int(entry["size"])
	var need_dl: int = int(size * 1.1) + 52428800
	var need_inst: int = size * 3
	var du: DirAccess = DirAccess.open(user_dir)
	if du != null and du.get_space_left() < need_dl:
		return {"ok": false, "error": "Not enough free disk space to download the update (about %d MB needed)." % (need_dl / 1048576)}
	var di: DirAccess = DirAccess.open(install)
	if di != null and di.get_space_left() < need_inst:
		return {"ok": false, "error": "Not enough free disk space in NovaSwift's folder to unpack the update (about %d MB needed)." % (need_inst / 1048576)}
	# 3. download (resumable), then verify the signed size + sha256
	_clean_downloads(user_dir, str(entry["asset"]))
	var dest: String = user_dir.path_join(str(entry["asset"]))
	var have: Dictionary = {"ok": false}
	if FileAccess.file_exists(dest):
		have = UpdateManifest.check_file(dest, entry)     # a complete earlier download
	if not bool(have["ok"]):
		DirAccess.remove_absolute(dest)
		_set_progress("Downloading...", 0.0)
		var dr: Dictionary = await _http.download(str(assets[str(entry["asset"])]), dest, size)
		if bool(dr.get("cancelled", false)) or _cancelled:
			return {"ok": false, "cancelled": true}
		if not bool(dr["ok"]):
			return {"ok": false, "error": str(dr["error"])}
	_set_progress("Verifying the download...", 1.0)
	var chk: Dictionary = await _threaded(UpdateManifest.check_file.bind(dest, entry))
	if _cancelled:
		return {"ok": false, "cancelled": true}
	if not bool(chk["ok"]):
		DirAccess.remove_absolute(dest)
		DirAccess.remove_absolute(dest + ".part")
		return {"ok": false, "error": str(chk["error"])}
	# 4. unpack beside the install (same filesystem as the swap) and validate
	_set_progress("Unpacking...", 1.0)
	var staging: String = install.path_join(UpdateConfig.STAGING_DIRNAME)
	UpdateInstall.remove_tree(staging)
	DirAccess.make_dir_recursive_absolute(staging)
	var ex: Dictionary = await _threaded(UpdateInstall.extract.bind(dest, staging))
	if not bool(ex["ok"]):
		UpdateInstall.remove_tree(staging)
		return {"ok": false, "error": str(ex["error"])}
	var root: String = UpdateInstall.payload_root(staging)
	var missing: PackedStringArray = UpdateInstall.missing_required(root, entry["required"])
	if not missing.is_empty():
		UpdateInstall.remove_tree(staging)
		return {"ok": false, "error": "The update is incomplete (missing %s)." % ", ".join(missing)}
	DirAccess.remove_absolute(dest)
	if _cancelled:
		UpdateInstall.remove_tree(staging)
		return {"ok": false, "cancelled": true}
	# 5. hand over: point of no return for this process
	_handing_off = true
	Prefs.set_value("updates", "pending_channel", channel)
	Prefs.save()
	var hr: Dictionary = UpdaterMode.launch(install, staging, install.path_join(str(entry["launcher"])),
		UpdateConfig.current_version(), str(rel["version"]))
	if not bool(hr["ok"]):
		_handing_off = false
		UpdateInstall.remove_tree(staging)
		return {"ok": false, "error": str(hr["error"])}
	return {"ok": true}


## Remove anything in user://update except `keep` (+ .part), the run dir and the state file.
func _clean_downloads(dir: String, keep: String) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f == "state.json" or f == keep or f == keep + ".part":
			continue
		DirAccess.remove_absolute(dir.path_join(f))


# --- after an update ----------------------------------------------------------------------------

## First main menu after start: settle a finished / failed update and remove leftovers.
func _housekeeping() -> void:
	if OS.has_feature("editor") or DisplayServer.get_name() == "headless":
		return
	var install: String = UpdateConfig.install_dir()
	UpdateInstall.remove_tree(install.path_join(UpdateConfig.STAGING_DIRNAME))
	UpdateInstall.remove_tree("user://update/run")
	var st: Dictionary = UpdateInstall.read_state()
	if st.is_empty():
		return
	UpdateInstall.clear_state()
	var status: String = str(st.get("status", ""))
	if status == "installed":
		if Semver.compare(UpdateConfig.current_version(), str(st.get("to", ""))) == 0 and Semver.is_valid(str(st.get("to", ""))):
			UpdateInstall.discard_backup(install)         # the new version started fine: the safety copy goes
			var pc: String = str(Prefs.get_value("updates", "pending_channel"))
			Prefs.set_value("updates", "installed_channel", pc if pc != "" else "stable")
			Prefs.set_value("updates", "pending_channel", "")
			Prefs.save()
			Alert.show(self, {"title": "NovaSwift updated", "message": "NovaSwift is now version %s." % UpdateConfig.current_version()})
		else:
			Alert.show(self, {"title": "Update problem", "message": "An update to %s was installed but this is still version %s. The previous files were kept in the .update_bak folder next to the game." % [st.get("to", "?"), UpdateConfig.current_version()]})
	elif status == "failed":
		UpdateInstall.recover(install)                    # finish a rollback that was interrupted, if any
		if not UpdateInstall.is_swapping(install):
			UpdateInstall.discard_backup(install)
		Alert.show(self, {"title": "Update failed", "message": "The last update could not be installed, so your previous version was restored.\n\n%s" % st.get("error", "")})

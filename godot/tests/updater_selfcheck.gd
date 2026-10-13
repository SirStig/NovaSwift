# Headless check of the auto-updater's logic (godot/updater/): semver, release selection, URL allow-list,
# manifest parsing + validation, RSA signature verification (test keypair made here), sha256 / size checks,
# archive extraction (zip + tar.gz, zip-slip), the file swap with rollback and crash recovery in a scratch
# folder, and updater-mode argument parsing. No network, no GDExtension, no data folder needed.
#   godot --headless --path godot -s res://tests/updater_selfcheck.gd
extends SceneTree

const Semver = preload("res://updater/Semver.gd")
const UpdateConfig = preload("res://updater/UpdateConfig.gd")
const UpdateChecker = preload("res://updater/UpdateChecker.gd")
const UpdateManifest = preload("res://updater/UpdateManifest.gd")
const UpdateInstall = preload("res://updater/UpdateInstall.gd")
const UpdaterMode = preload("res://updater/UpdaterMode.gd")

var _fails: int = 0
var _scratch: String = ""


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "<missing>"


func _init() -> void:
	_scratch = OS.get_user_data_dir().path_join("updater_selfcheck")
	UpdateInstall.remove_tree(_scratch)
	DirAccess.make_dir_recursive_absolute(_scratch)
	_semver()
	_urls()
	_release_selection()
	_channels()
	_manifest_and_signature()
	_hashes()
	_extraction()
	_swap()
	_args()
	UpdateInstall.remove_tree(_scratch)
	print("updater_selfcheck: %s (%d failure(s))" % ["OK" if _fails == 0 else "FAILED", _fails])
	quit(0 if _fails == 0 else 1)


# --- semver ------------------------------------------------------------------------------------

func _semver() -> void:
	_ok(Semver.compare("1.0.0", "1.0.0") == 0, "semver equal")
	_ok(Semver.compare("1.0.1", "1.0.0") == 1, "semver patch")
	_ok(Semver.compare("1.10.0", "1.9.9") == 1, "semver numeric (1.10 > 1.9, not lexical)")
	_ok(Semver.compare("2.0.0", "10.0.0") == -1, "semver major numeric")
	_ok(Semver.compare("1.0.0-beta.1", "1.0.0") == -1, "pre-release below its release")
	_ok(Semver.compare("1.0.0-beta.2", "1.0.0-beta.10") == -1, "pre-release numeric ids")
	_ok(Semver.compare("1.0.0-alpha", "1.0.0-beta") == -1, "pre-release alphanumeric ids")
	_ok(Semver.compare("1.0.0-alpha", "1.0.0-alpha.1") == -1, "shorter pre-release set is lower")
	_ok(Semver.compare("1.0.0-1", "1.0.0-alpha") == -1, "numeric id below alphanumeric")
	_ok(Semver.compare("v1.2.3+build5", "1.2.3") == 0, "leading v and build metadata ignored")
	_ok(Semver.is_newer("1.0.1", "1.0.0"), "is_newer true")
	_ok(not Semver.is_newer("1.0.0", "1.0.1"), "never a downgrade")
	_ok(not Semver.is_newer("1.0.0", "1.0.0"), "same version is not newer")
	_ok(Semver.is_newer("1.1.0", "1.1.0-beta.3"), "release is newer than its beta")
	_ok(not Semver.is_newer("1.0.0-beta.1", "1.0.0"), "beta of the current release is not newer")
	for bad in ["", "1", "1.2", "1.2.3.4", "a.b.c", "01.2.3", "1.2.3-", "1.2.-3", "1.2.3-be ta", "v", "1.2.3-01"]:
		_ok(Semver.parse(bad).is_empty(), "invalid semver rejected: '%s'" % bad)
	_ok(not Semver.is_newer("garbage", "1.0.0") and not Semver.is_newer("1.0.1", "garbage"), "invalid never newer")


# --- URLs --------------------------------------------------------------------------------------

func _urls() -> void:
	_ok(UpdateConfig.url_allowed("https://api.github.com/repos/SirStig/NovaSwift/releases"), "api.github.com allowed")
	_ok(UpdateConfig.url_allowed("https://github.com/SirStig/NovaSwift/releases/download/v1/a.zip"), "github.com allowed")
	_ok(UpdateConfig.url_allowed("https://objects.githubusercontent.com/x?y=1"), "objects.githubusercontent.com allowed")
	_ok(UpdateConfig.url_allowed("https://release-assets.githubusercontent.com/x"), "release-assets host allowed")
	_ok(not UpdateConfig.url_allowed("http://github.com/x"), "plain http refused")
	_ok(not UpdateConfig.url_allowed("https://evil.example.com/x"), "other host refused")
	_ok(not UpdateConfig.url_allowed("https://github.com.evil.com/x"), "look-alike host refused")
	_ok(not UpdateConfig.url_allowed("https://evil.com@github.com/x"), "userinfo trick refused")
	_ok(not UpdateConfig.url_allowed("https://github.com:8443/x"), "non-default port refused")
	_ok(not UpdateConfig.url_allowed("ftp://github.com/x"), "other scheme refused")
	_ok(not UpdateConfig.url_allowed("//github.com/x") and not UpdateConfig.url_allowed("/relative"), "relative refused")


# --- release selection -------------------------------------------------------------------------

func _rel(tag: String, pre: bool, draft: bool, with_assets: bool) -> Dictionary:
	var assets: Array = []
	if with_assets:
		for n in ["update.json", "update.json.sig", "NovaSwift-linux-x86_64.tar.gz"]:
			assets.append({"name": n, "browser_download_url": UpdateConfig.ASSET_PREFIX + tag + "/" + n})
	return {"tag_name": tag, "name": "NovaSwift " + tag, "body": "## Changes\n- **Fast** [link](http://x)\n", "prerelease": pre,
		"draft": draft, "html_url": "https://github.com/SirStig/NovaSwift/releases/tag/" + tag, "assets": assets}


func _release_selection() -> void:
	var list: Array = [_rel("v1.0.0", false, false, true), _rel("v1.1.0", false, false, true), _rel("v1.2.0-beta.1", true, false, true),
		_rel("v1.3.0", false, true, true), _rel("v1.1.5", false, false, false), _rel("nightly", false, false, true)]
	var stable: Dictionary = UpdateChecker.pick_release(list, "1.0.0", false)
	_ok(str(stable.get("version", "")) == "1.1.0", "stable channel picks 1.1.0 (skips beta, draft, no-assets, junk tag)")
	var beta: Dictionary = UpdateChecker.pick_release(list, "1.0.0", true)
	_ok(str(beta.get("version", "")) == "1.2.0-beta.1", "beta channel picks the newest incl. pre-release")
	_ok(UpdateChecker.pick_release(list, "1.1.0", false).is_empty(), "nothing to offer when current")
	_ok(UpdateChecker.pick_release(list, "9.0.0", true).is_empty(), "never offers a downgrade")
	_ok(not UpdateChecker.pick_release(list, "1.0.0", false, false).is_empty(), "need_assets=false still works")
	_ok(str(UpdateChecker.pick_release(list, "1.0.0", false, false).get("version", "")) == "1.1.5", "need_assets=false sees the asset-less 1.1.5")
	_ok(UpdateChecker.pick_release("not an array", "1.0.0", false).is_empty(), "malformed JSON -> nothing")
	_ok(UpdateChecker.pick_release([1, "x", null], "1.0.0", false).is_empty(), "malformed entries skipped")
	var notes: String = UpdateChecker.clean_notes("## Changes\n- **Fast** [link](http://x)\n")
	_ok(notes.contains("CHANGES") and notes.contains("\u2022 Fast link") and not notes.contains("http"), "release notes cleaned: '%s'" % notes)


# --- channels ----------------------------------------------------------------------------------

func _channels() -> void:
	var flagged: Dictionary = _rel("v1.3.0", true, false, true)           # GitHub pre-release flag, plain tag
	var suffixed: Dictionary = _rel("v1.4.0-experimental.1", false, false, true)   # suffix, flag not set
	var rc: Dictionary = _rel("v1.5.0-rc.1", false, false, true)
	var plain: Dictionary = _rel("v1.2.0", false, false, true)
	var list: Array = [plain, flagged, suffixed, rc]
	var by_tag: Dictionary = {}
	for r in UpdateChecker.eligible(list, true):
		by_tag[str(r["tag"])] = str(r["channel"])
	_ok(by_tag["v1.3.0"] == "experimental", "GitHub pre-release flag marks experimental")
	_ok(by_tag["v1.4.0-experimental.1"] == "experimental" and by_tag["v1.5.0-rc.1"] == "experimental", "semver suffix marks experimental")
	_ok(by_tag["v1.2.0"] == "stable", "plain release is stable")
	_ok(UpdateChecker.candidates(list, "1.0.0", false).size() == 1, "experimental off: only the stable release is a candidate")
	var all_c: Array = UpdateChecker.candidates(list, "1.0.0", true)
	_ok(all_c.size() == 4 and str(all_c[0]["version"]) == "1.5.0-rc.1" and str(all_c[3]["version"]) == "1.2.0", "experimental on: all candidates, newest first")
	_ok(str(UpdateChecker.newest_stable(list)["version"]) == "1.2.0", "newest_stable ignores experimental releases")
	_ok(UpdateChecker.newest_stable([flagged, suffixed]).is_empty(), "no stable release -> {}")
	# the signed channel is optional but, when present, must be known
	var good: Dictionary = UpdateManifest.parse('{"schema":1,"version":"1.3.0","channel":"experimental","platforms":{}}'.to_utf8_buffer())
	_ok(bool(good["ok"]) and UpdateManifest.channel_of(good["manifest"], "stable") == "experimental", "signed channel read (wins over the GitHub flag)")
	var none: Dictionary = UpdateManifest.parse('{"schema":1,"version":"1.3.0","platforms":{}}'.to_utf8_buffer())
	_ok(UpdateManifest.channel_of(none["manifest"], "experimental") == "experimental", "no signed channel -> fallback label")
	_ok(not bool(UpdateManifest.parse('{"schema":1,"version":"1.3.0","channel":"nightly","platforms":{}}'.to_utf8_buffer())["ok"]), "unknown channel rejected")
	_ok(UpdateManifest.channel_of(UpdateManifest.parse('{"schema":1,"version":"1.3.0","channel":"stable","platforms":{}}'.to_utf8_buffer())["manifest"], "experimental") == "stable", "signed stable overrides a flagged release")


# --- manifest + signature ----------------------------------------------------------------------

func _manifest_bytes(extra: Dictionary = {}) -> PackedByteArray:
	var plat: Dictionary = {"asset": "NovaSwift-linux-x86_64.tar.gz", "size": 1234, "sha256": "ab".repeat(32),
		"launcher": "NovaSwift.sh", "required": ["NovaSwift.sh", "NovaSwift.x86_64", "NovaSwift.pck"]}
	plat.merge(extra, true)
	var m: Dictionary = {"schema": 1, "version": "1.2.0", "min_updater": 1, "platforms": {"linux-x86_64": plat}}
	return JSON.stringify(m).to_utf8_buffer()


func _manifest_and_signature() -> void:
	var crypto: Crypto = Crypto.new()
	var key: CryptoKey = crypto.generate_rsa(2048)
	var pub_pem: String = key.save_to_string(true)
	var data: PackedByteArray = _manifest_bytes()
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	var sig: PackedByteArray = crypto.sign(HashingContext.HASH_SHA256, ctx.finish(), key)
	_ok(UpdateManifest.verify_signature(data, sig, pub_pem), "valid signature verifies")
	var tampered: PackedByteArray = data.duplicate()
	tampered[tampered.size() - 3] = tampered[tampered.size() - 3] ^ 1
	_ok(not UpdateManifest.verify_signature(tampered, sig, pub_pem), "tampered manifest rejected")
	var bad_sig: PackedByteArray = sig.duplicate()
	bad_sig[0] = bad_sig[0] ^ 1
	_ok(not UpdateManifest.verify_signature(data, bad_sig, pub_pem), "tampered signature rejected")
	var other: CryptoKey = crypto.generate_rsa(2048)
	_ok(not UpdateManifest.verify_signature(data, sig, other.save_to_string(true)), "signature from another key rejected")
	_ok(not UpdateManifest.verify_signature(data, PackedByteArray(), pub_pem), "empty signature rejected")
	_ok(not UpdateManifest.verify_signature(data, sig, "-----BEGIN PLACEHOLDER-----\nx\n-----END PLACEHOLDER-----"), "placeholder key rejects everything")
	_ok(not UpdateManifest.verify_signature(data, sig, ""), "no key rejects everything")

	var parsed: Dictionary = UpdateManifest.parse(data)
	_ok(bool(parsed["ok"]), "manifest parses")
	var entry: Dictionary = UpdateManifest.platform_entry(parsed["manifest"], "linux-x86_64")
	_ok(not entry.is_empty() and int(entry["size"]) == 1234 and str(entry["launcher"]) == "NovaSwift.sh", "platform entry normalised")
	_ok(UpdateManifest.platform_entry(parsed["manifest"], "windows-x86_64").is_empty(), "missing platform -> {}")
	_ok(not bool(UpdateManifest.parse("not json".to_utf8_buffer())["ok"]), "garbage manifest rejected")
	_ok(not bool(UpdateManifest.parse('{"schema":2,"version":"1.0.0","platforms":{}}'.to_utf8_buffer())["ok"]), "unknown schema rejected")
	_ok(not bool(UpdateManifest.parse('{"schema":1,"version":"x","platforms":{}}'.to_utf8_buffer())["ok"]), "bad version rejected")
	for bad in [{"sha256": "zz".repeat(32)}, {"sha256": "ab"}, {"size": 0}, {"asset": "../evil.tar.gz"}, {"asset": "a/b.zip"},
			{"launcher": "../x"}, {"launcher": "/abs"}, {"launcher": "C:\\x"}, {"required": ["../x"]}, {"required": "NovaSwift.sh"}]:
		var pm: Dictionary = UpdateManifest.parse(_manifest_bytes(bad))
		_ok(UpdateManifest.platform_entry(pm["manifest"], "linux-x86_64").is_empty(), "invalid platform entry rejected: %s" % str(bad))
	_ok(UpdateManifest.safe_rel("a/b.txt") and not UpdateManifest.safe_rel("a/../b") and not UpdateManifest.safe_rel("a//b"), "safe_rel")
	_ok(not UpdateConfig.has_signing_key() or UpdateConfig.pubkey_pem().contains("BEGIN PUBLIC KEY"), "placeholder / real key handled")


# --- sha256 + size -----------------------------------------------------------------------------

func _hashes() -> void:
	var p: String = _scratch.path_join("blob.bin")
	_write(p, "hello update")
	var good: Dictionary = {"size": 12, "sha256": FileAccess.get_sha256(p)}
	_ok(bool(UpdateManifest.check_file(p, good)["ok"]), "size + sha256 match")
	_ok(not bool(UpdateManifest.check_file(p, {"size": 12, "sha256": "00".repeat(32)})["ok"]), "sha256 mismatch rejected")
	_ok(not bool(UpdateManifest.check_file(p, {"size": 13, "sha256": good["sha256"]})["ok"]), "size mismatch rejected")
	_ok(not bool(UpdateManifest.check_file(_scratch.path_join("nope.bin"), good)["ok"]), "missing file rejected")


# --- extraction --------------------------------------------------------------------------------

func _extraction() -> void:
	var zp: String = _scratch.path_join("pkg.zip")
	var packer: ZIPPacker = ZIPPacker.new()
	packer.open(zp)
	for n in ["NovaSwift/NovaSwift.exe", "NovaSwift/NovaSwift.pck", "NovaSwift/sub/lib.dll"]:
		packer.start_file(n)
		packer.write_file(("data of " + n).to_utf8_buffer())
		packer.close_file()
	packer.close()
	var dest: String = _scratch.path_join("zip_out")
	var r: Dictionary = UpdateInstall.extract(zp, dest)
	_ok(bool(r["ok"]), "zip extracts")
	var root: String = UpdateInstall.payload_root(dest)
	_ok(root.ends_with("/NovaSwift"), "payload_root descends the single wrapper folder")
	_ok(UpdateInstall.missing_required(root, ["NovaSwift.exe", "NovaSwift.pck", "sub/lib.dll"]).is_empty(), "required files present")
	_ok(UpdateInstall.missing_required(root, ["NovaSwift.exe", "nope.dll"]).size() == 1, "missing required file reported")
	_ok(_read(root.path_join("sub/lib.dll")) == "data of NovaSwift/sub/lib.dll", "zip file contents intact")

	var evil: String = _scratch.path_join("evil.zip")
	var p2: ZIPPacker = ZIPPacker.new()
	p2.open(evil)
	p2.start_file("../escaped.txt")
	p2.write_file("x".to_utf8_buffer())
	p2.close_file()
	p2.close()
	var re: Dictionary = UpdateInstall.extract(evil, _scratch.path_join("evil_out"))
	_ok(not bool(re["ok"]) and not FileAccess.file_exists(_scratch.path_join("escaped.txt")), "zip-slip entry rejected")

	if OS.get_name() != "Windows":
		var src: String = _scratch.path_join("tar_src/NovaSwift")
		_write(src.path_join("NovaSwift.sh"), "#!/bin/sh\n")
		FileAccess.set_unix_permissions(src.path_join("NovaSwift.sh"), 0x1ED)
		_write(src.path_join("NovaSwift.pck"), "pck")
		var tgz: String = _scratch.path_join("pkg.tar.gz")
		var out: Array = []
		var code: int = OS.execute("tar", ["-czf", tgz, "-C", _scratch.path_join("tar_src"), "NovaSwift"], out, true)
		if code == 0:
			var td: String = _scratch.path_join("tar_out")
			var rt: Dictionary = UpdateInstall.extract(tgz, td)
			_ok(bool(rt["ok"]), "tar.gz extracts")
			var troot: String = UpdateInstall.payload_root(td)
			_ok(UpdateInstall.missing_required(troot, ["NovaSwift.sh", "NovaSwift.pck"]).is_empty(), "tar.gz payload complete")
			_ok((FileAccess.get_unix_permissions(troot.path_join("NovaSwift.sh")) & 0x40) != 0, "tar.gz keeps the exec bit")
		else:
			print("SKIP tar.gz (tar unavailable, exit %d)" % code)


# --- swap, rollback, recovery ------------------------------------------------------------------

func _make_install(name: String) -> Array:
	var base: String = _scratch.path_join(name)
	UpdateInstall.remove_tree(base)
	var install: String = base.path_join("install")
	var payload: String = base.path_join("install/.update_new/NovaSwift")
	_write(install.path_join("NovaSwift.sh"), "old launcher")
	_write(install.path_join("NovaSwift.x86_64"), "old exe")
	_write(install.path_join("NovaSwift.pck"), "old pck")
	_write(install.path_join("libold.so"), "stale lib the new package no longer ships")
	_write(install.path_join("data/keep.txt"), "user data")
	_write(payload.path_join("NovaSwift.sh"), "new launcher")
	_write(payload.path_join("NovaSwift.x86_64"), "new exe")
	_write(payload.path_join("NovaSwift.pck"), "new pck")
	_write(payload.path_join("libnew.so"), "new lib")
	_write(payload.path_join("data/should_not_overwrite.txt"), "package data")
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(payload.path_join("NovaSwift.x86_64"), 0x1ED)
	return [install, payload]


func _swap() -> void:
	var s: Array = _make_install("swap_ok")
	var install: String = s[0]
	var payload: String = s[1]
	var r: Dictionary = UpdateInstall.apply(install, payload)
	_ok(bool(r["ok"]), "swap succeeds")
	_ok(_read(install.path_join("NovaSwift.pck")) == "new pck" and _read(install.path_join("libnew.so")) == "new lib", "new files in place")
	_ok(_read(install.path_join("libold.so")).begins_with("stale"), "files the package does not ship are left alone")
	_ok(_read(install.path_join("data/keep.txt")) == "user data" and not FileAccess.file_exists(install.path_join("data/should_not_overwrite.txt")), "preserved folders untouched")
	_ok(_read(install.path_join(".update_bak/NovaSwift.pck")) == "old pck", "old files kept in the backup folder")
	if OS.get_name() != "Windows":
		_ok((FileAccess.get_unix_permissions(install.path_join("NovaSwift.x86_64")) & 0x40) != 0, "exec bit survives the swap")
	_ok(not UpdateInstall.is_swapping(install), "journal says done")
	UpdateInstall.discard_backup(install)
	_ok(not DirAccess.dir_exists_absolute(install.path_join(".update_bak")), "backup discarded after a good start")

	# failure half-way: everything is restored, nothing new is left behind
	var f: Array = _make_install("swap_fail")
	var fr: Dictionary = UpdateInstall.apply(f[0], f[1], {"fail_after": 2})
	_ok(not bool(fr["ok"]) and bool(fr["rolled_back"]), "injected failure reports a rollback")
	_ok(_read(f[0].path_join("NovaSwift.pck")) == "old pck" and _read(f[0].path_join("NovaSwift.sh")) == "old launcher"
		and _read(f[0].path_join("NovaSwift.x86_64")) == "old exe", "rollback restored every old file")
	_ok(not FileAccess.file_exists(f[0].path_join("libnew.so")), "rollback removed newly added files")
	_ok(_read(f[0].path_join("data/keep.txt")) == "user data", "rollback left user data alone")
	_ok(not DirAccess.dir_exists_absolute(f[0].path_join(".update_bak")), "backup folder removed after rollback")

	# crash recovery: a journal still saying "swapping" is rolled back by recover()
	var c: Array = _make_install("swap_crash")
	var cinstall: String = c[0]
	var backup: String = UpdateInstall.backup_dir(cinstall)
	DirAccess.make_dir_recursive_absolute(backup)
	DirAccess.rename_absolute(cinstall.path_join("NovaSwift.pck"), backup.path_join("NovaSwift.pck"))
	_write(cinstall.path_join("NovaSwift.pck"), "half-written new pck")
	_write(cinstall.path_join("libnew.so"), "half-installed new lib")
	_write(backup.path_join("journal.json"), JSON.stringify({"state": "swapping", "replaced": ["NovaSwift.pck"], "added": ["libnew.so"]}))
	_ok(UpdateInstall.is_swapping(cinstall), "unfinished journal detected")
	_ok(UpdateInstall.recover(cinstall), "recover() rolls the crashed swap back")
	_ok(_read(cinstall.path_join("NovaSwift.pck")) == "old pck" and not FileAccess.file_exists(cinstall.path_join("libnew.so")), "crash recovery restored the install")

	# state note for the next game start
	UpdateInstall.write_state({"status": "installed", "to": "1.2.0"})
	_ok(str(UpdateInstall.read_state().get("status", "")) == "installed", "state round-trips")
	UpdateInstall.clear_state()
	_ok(UpdateInstall.read_state().is_empty(), "state cleared")


# --- updater mode args -------------------------------------------------------------------------

func _args() -> void:
	var o: Dictionary = UpdaterMode.parse_args(PackedStringArray(["--", "--updater", "--install-dir", "/opt/NovaSwift", "--staging",
		"/opt/NovaSwift/.update_new", "--pid", "4242", "--relaunch", "/opt/NovaSwift/NovaSwift.sh", "--from", "1.0.0", "--to=1.1.0"]))
	_ok(str(o.get("install_dir", "")) == "/opt/NovaSwift" and int(o.get("pid", 0)) == 4242, "updater args parsed")
	_ok(str(o.get("relaunch", "")) == "/opt/NovaSwift/NovaSwift.sh" and str(o.get("to", "")) == "1.1.0" and str(o.get("from", "")) == "1.0.0", "updater args (incl. --key=value) parsed")
	_ok(UpdaterMode.parse_args(PackedStringArray(["--path", "godot"])).is_empty(), "no --updater -> normal game")
	_ok(UpdaterMode.parse_args(PackedStringArray(["--updater", "--pid", "1"])).is_empty(), "--updater without dirs is not honoured")
	_ok(not UpdaterMode.pid_alive(0) and UpdaterMode.pid_alive(OS.get_process_id()), "pid_alive: self alive, 0 dead")

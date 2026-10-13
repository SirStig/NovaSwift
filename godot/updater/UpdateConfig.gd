# NOVA Swift updater -- constants and environment probes shared by every updater piece.
# See docs/UPDATER.md. Loaded with preload() (no class_name).
extends RefCounted

const UpdatePubKey = preload("res://updater/UpdatePubKey.gd")
const Semver = preload("res://updater/Semver.gd")

const REPO := "SirStig/NovaSwift"
const API_RELEASES := "https://api.github.com/repos/SirStig/NovaSwift/releases?per_page=30"
const RELEASES_PAGE := "https://github.com/SirStig/NovaSwift/releases"
## Only these hosts are ever contacted (initial URLs and every redirect hop), HTTPS only.
const ALLOWED_HOSTS := ["api.github.com", "github.com", "objects.githubusercontent.com",
	"release-assets.githubusercontent.com", "github-releases.githubusercontent.com"]
## Release asset URLs must live under this prefix.
const ASSET_PREFIX := "https://github.com/SirStig/NovaSwift/releases/download/"
const MANIFEST_ASSET := "update.json"
const SIGNATURE_ASSET := "update.json.sig"
## Protocol version of this updater; a manifest with min_updater above it needs a newer game (download page).
const UPDATER_VERSION := 1
const CHECK_INTERVAL_SEC := 86400
## Minimum wait after a FAILED check before the next automatic attempt.
const RETRY_INTERVAL_SEC := 3600
const MAX_NOTES_CHARS := 6000
const STAGING_DIRNAME := ".update_new"
const BACKUP_DIRNAME := ".update_bak"
## Top-level names inside the install dir that an update never touches (none ship in the package today;
## pilots, prefs and game data live in user:// and ~/.local/share/NovaSwift).
const PRESERVE := ["data", "Pilots", "pilots", "plugins", "user", "portable.txt"]


static func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## "linux-x86_64" / "windows-x86_64" / "macos-<arch>" -- the key into the manifest's platforms table.
static func platform_key() -> String:
	return "%s-%s" % [OS.get_name().to_lower(), Engine.get_architecture_name()]


static func install_dir() -> String:
	return OS.get_executable_path().get_base_dir()


## The PEM of the update-signing public key, or "" when this build has none (placeholder).
static func pubkey_pem() -> String:
	var pem: String = ""
	if FileAccess.file_exists("res://updater/update_pubkey.pem"):
		pem = FileAccess.get_file_as_string("res://updater/update_pubkey.pem")
	if not _is_real_pem(pem):
		pem = UpdatePubKey.PEM
	return pem if _is_real_pem(pem) else ""


static func _is_real_pem(pem: String) -> bool:
	return pem.contains("-----BEGIN PUBLIC KEY-----") and not pem.contains("PLACEHOLDER")


static func has_signing_key() -> bool:
	return pubkey_pem() != ""


## Why checking for updates is off for this process ("" = it can run).
static func check_blocker() -> String:
	if OS.has_feature("editor"):
		return "Development build."
	if DisplayServer.get_name() == "headless":
		return "Headless run."
	if not has_signing_key():
		return "Unsigned build: updates are disabled."
	if not Semver.is_valid(current_version()):
		return "This build has no valid version number."
	return ""


## Why updates cannot be INSTALLED automatically here ("" = they can). The download page is offered instead.
static func install_blocker() -> String:
	var os_name: String = OS.get_name()
	if os_name != "Linux" and os_name != "Windows":
		return "Automatic install is only available on Linux and Windows."
	if Engine.get_architecture_name() != "x86_64":
		return "Automatic install supports x86_64 only."
	if OS.has_feature("editor"):
		return "Development build."
	var exe: String = OS.get_executable_path()
	if exe.replace("\\", "/").to_lower().contains("/steamapps/common/"):
		return "This copy is managed by Steam, which updates it itself."
	if os_name == "Linux":
		if OS.get_environment("FLATPAK_ID") != "" or FileAccess.file_exists("/.flatpak-info"):
			return "Flatpak installs are updated through Flatpak."
		if OS.get_environment("APPIMAGE") != "" or OS.get_environment("APPDIR") != "":
			return "AppImage installs cannot update themselves."
		if OS.get_environment("SNAP") != "":
			return "Snap installs are updated through Snap."
	if not dir_writable(install_dir()):
		return "NovaSwift's folder is read-only, so it cannot replace itself."
	return ""


## True if a file can be created (and removed) in `dir`.
static func dir_writable(dir: String) -> bool:
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return false
	var probe: String = dir.path_join(".nova_write_probe_%d" % Time.get_ticks_usec())
	var f: FileAccess = FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.store_8(0)
	f.close()
	DirAccess.remove_absolute(probe)
	return true


## Parts of an absolute URL: {scheme, host, port, path}; {} if it does not look like scheme://host[:port]/...
static func parse_url(url: String) -> Dictionary:
	var sep: int = url.find("://")
	if sep <= 0:
		return {}
	var scheme: String = url.substr(0, sep).to_lower()
	var rest: String = url.substr(sep + 3)
	var end: int = rest.length()
	for ch in ["/", "?", "#"]:
		var i: int = rest.find(ch)
		if i >= 0 and i < end:
			end = i
	var authority: String = rest.substr(0, end)
	var path: String = rest.substr(end)
	if authority == "" or authority.contains("@") or authority.contains(" ") or authority.contains("\\"):
		return {}
	var host: String = authority
	var port: int = 443
	var colon: int = authority.rfind(":")
	if colon >= 0:
		host = authority.substr(0, colon)
		var ps: String = authority.substr(colon + 1)
		if not ps.is_valid_int():
			return {}
		port = int(ps)
	return {"scheme": scheme, "host": host.to_lower(), "port": port, "path": path}


## HTTPS, default port, allow-listed host -- for the first request and every redirect hop alike.
static func url_allowed(url: String) -> bool:
	var u: Dictionary = parse_url(url)
	if u.is_empty():
		return false
	return str(u["scheme"]) == "https" and int(u["port"]) == 443 and ALLOWED_HOSTS.has(str(u["host"]))


## UTC "now" in Unix seconds (the Prefs timestamps).
static func now() -> int:
	return int(Time.get_unix_time_from_system())

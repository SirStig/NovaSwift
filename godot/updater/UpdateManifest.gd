# NOVA Swift updater -- the signed release manifest (update.json): parsing, signature check, asset check.
#
#   {"schema": 1, "version": "1.2.0", "min_updater": 1, "published": "2026-10-20T12:00:00Z",
#    "platforms": {"linux-x86_64":   {"asset": "NovaSwift-linux-x86_64.tar.gz", "size": 123, "sha256": "<64 hex>",
#                                     "launcher": "NovaSwift.sh",
#                                     "required": ["NovaSwift.sh", "NovaSwift.x86_64", "NovaSwift.pck"]},
#                  "windows-x86_64": {"asset": "NovaSwift-windows-x86_64.zip", ...}}}
#
# update.json.sig is the RAW RSA signature (PKCS#1 v1.5, SHA-256) over the exact bytes of update.json,
# produced by scripts/release-sign.sh. Nothing in the manifest is trusted before verify_signature() passes.
# Loaded with preload() (no class_name).
extends RefCounted

const Semver = preload("res://updater/Semver.gd")

const MAX_MANIFEST_BYTES := 262144


## True iff `signature` is a valid RSA / SHA-256 signature of `data` under the PEM public key.
static func verify_signature(data: PackedByteArray, signature: PackedByteArray, pem: String) -> bool:
	if data.is_empty() or signature.is_empty() or pem == "":
		return false
	var key: CryptoKey = CryptoKey.new()
	if key.load_from_string(pem, true) != OK:
		return false
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	var digest: PackedByteArray = ctx.finish()
	var crypto: Crypto = Crypto.new()
	return crypto.verify(HashingContext.HASH_SHA256, digest, signature, key)


## A relative path that stays inside its folder: no "..", no absolute / drive / backslash forms.
static func safe_rel(path: String) -> bool:
	if path == "" or path.begins_with("/") or path.contains("\\") or path.contains(":"):
		return false
	for seg in path.split("/"):
		if seg == "" or seg == "." or seg == "..":
			return false
	return true


static func _is_hex64(s: String) -> bool:
	if s.length() != 64:
		return false
	for i in 64:
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


static func _asset_name_ok(s: String) -> bool:
	if s == "" or s.length() > 128:
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		var ok: bool = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 46 or c == 45 or c == 95
		if not ok:
			return false
	return not s.begins_with(".")


## Parse manifest bytes (call AFTER verify_signature). {ok, error, manifest}.
static func parse(data: PackedByteArray) -> Dictionary:
	if data.size() > MAX_MANIFEST_BYTES:
		return {"ok": false, "error": "The update manifest is too large."}
	var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"ok": false, "error": "The update manifest is not valid JSON."}
	var m: Dictionary = parsed
	if int(m.get("schema", 0)) != 1:
		return {"ok": false, "error": "The update manifest uses an unknown schema."}
	if not (m.get("version") is String) or not Semver.is_valid(str(m["version"])):
		return {"ok": false, "error": "The update manifest has no valid version."}
	if not (m.get("platforms") is Dictionary):
		return {"ok": false, "error": "The update manifest lists no platforms."}
	if m.has("channel") and not (["stable", "experimental"].has(str(m["channel"]))):
		return {"ok": false, "error": "The update manifest has an unknown channel."}
	return {"ok": true, "error": "", "manifest": m}


## The validated entry of `manifest` for `platform` ("linux-x86_64"), or {} (also when malformed).
## Normalised: {asset, size:int, sha256, launcher, required:Array[String]}.
static func platform_entry(manifest: Dictionary, platform: String) -> Dictionary:
	var plats: Variant = manifest.get("platforms")
	if not (plats is Dictionary) or not (plats as Dictionary).has(platform):
		return {}
	var e: Variant = (plats as Dictionary)[platform]
	if not (e is Dictionary):
		return {}
	var d: Dictionary = e
	var asset: String = str(d.get("asset", ""))
	var sha: String = str(d.get("sha256", "")).to_lower()
	var size: int = int(d.get("size", 0))
	var launcher: String = str(d.get("launcher", ""))
	if not _asset_name_ok(asset) or not _is_hex64(sha) or size <= 0 or not safe_rel(launcher):
		return {}
	var required: Array = []
	var raw: Variant = d.get("required", [launcher])
	if not (raw is Array):
		return {}
	for r in raw:
		if not (r is String) or not safe_rel(str(r)):
			return {}
		required.append(str(r))
	if not required.has(launcher):
		required.append(launcher)
	return {"asset": asset, "size": size, "sha256": sha, "launcher": launcher, "required": required}


## Size + SHA-256 of a downloaded file against a platform entry. {ok, error}.
static func check_file(path: String, entry: Dictionary) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "The downloaded update file is missing."}
	var size: int = f.get_length()
	f.close()
	if size != int(entry["size"]):
		return {"ok": false, "error": "The downloaded update is the wrong size (%d bytes, expected %d)." % [size, int(entry["size"])]}
	var sha: String = FileAccess.get_sha256(path)
	if sha != str(entry["sha256"]):
		return {"ok": false, "error": "The downloaded update does not match its signed checksum, so it was rejected."}
	return {"ok": true, "error": ""}


## The signed channel ("stable" | "experimental") or `fallback` when the manifest names none.
static func channel_of(manifest: Dictionary, fallback: String) -> String:
	return str(manifest["channel"]) if manifest.has("channel") else fallback

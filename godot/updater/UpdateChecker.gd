# NOVA Swift updater -- choosing the release to offer from the GitHub releases listing (pure, no network).
# Loaded with preload() (no class_name).
extends RefCounted

const UpdateConfig = preload("res://updater/UpdateConfig.gd")
const Semver = preload("res://updater/Semver.gd")


## A release tag we accept: "v" + a valid semver (v1.2.3, v1.2.3-beta.1).
static func tag_version(tag: String) -> String:
	if not tag.begins_with("v"):
		return ""
	var v: String = tag.substr(1)
	return v if Semver.is_valid(v) else ""


## True if a release looks experimental: GitHub's pre-release flag OR a semver pre-release suffix on the tag
## (v1.3.0-experimental.1, -beta.2, -rc.1). The signed manifest's "channel" overrides this once it is verified.
static func looks_experimental(rel: Dictionary, version: String) -> bool:
	return bool(rel.get("prerelease", false)) or Semver.is_prerelease(version)


## Every installable (non-draft, valid tag, with update.json + .sig when `need_assets`) release in the listing,
## as {tag, version, name, body, html_url, prerelease, channel, assets}, channel = "experimental" | "stable"
## from the GitHub flag / tag only. Unsorted.
static func eligible(releases: Variant, need_assets: bool) -> Array:
	var out: Array = []
	if not (releases is Array):
		return out
	for r in releases:
		if not (r is Dictionary):
			continue
		var rel: Dictionary = r
		if bool(rel.get("draft", false)):
			continue
		var tag: String = str(rel.get("tag_name", ""))
		var ver: String = tag_version(tag)
		if ver == "":
			continue
		var assets: Dictionary = {}
		var raw: Variant = rel.get("assets", [])
		if raw is Array:
			for a in raw:
				if a is Dictionary:
					var nm: String = str((a as Dictionary).get("name", ""))
					var url: String = str((a as Dictionary).get("browser_download_url", ""))
					if nm != "" and url.begins_with(UpdateConfig.ASSET_PREFIX) and UpdateConfig.url_allowed(url):
						assets[nm] = url
		if need_assets and not (assets.has(UpdateConfig.MANIFEST_ASSET) and assets.has(UpdateConfig.SIGNATURE_ASSET)):
			continue
		var page: String = str(rel.get("html_url", ""))
		if not page.begins_with("https://github.com/" + UpdateConfig.REPO + "/"):
			page = UpdateConfig.RELEASES_PAGE
		var exp: bool = looks_experimental(rel, ver)
		out.append({"tag": tag, "version": ver, "name": str(rel.get("name", "")), "body": str(rel.get("body", "")),
			"html_url": page, "prerelease": exp, "gh_prerelease": bool(rel.get("prerelease", false)),
			"channel": "experimental" if exp else "stable", "assets": assets})
	return out


static func _sort_desc(list: Array) -> Array:
	var out: Array = list.duplicate()
	for i in range(1, out.size()):
		var j: int = i
		while j > 0 and Semver.is_newer(str(out[j]["version"]), str(out[j - 1]["version"])):
			var t: Variant = out[j]
			out[j] = out[j - 1]
			out[j - 1] = t
			j -= 1
	return out


## Releases strictly newer than `current`, newest first. Experimental-looking ones only when `experimental`.
static func candidates(releases: Variant, current: String, experimental: bool, need_assets: bool = true) -> Array:
	var list: Array = []
	for rel in eligible(releases, need_assets):
		# With experimental off, skip only releases GitHub flags as pre-release. A suffix-only "experimental" guess
		# (e.g. a full release tagged v0.7.0-beta.2) stays a candidate: its SIGNED manifest channel decides later,
		# so a stable-signed beta-named release reaches everyone and an experimental-signed one is still refused.
		if str(rel["channel"]) == "experimental" and not experimental and bool(rel.get("gh_prerelease", true)):
			continue
		if Semver.is_newer(str(rel["version"]), current):
			list.append(rel)
	return _sort_desc(list)


## The newest stable release regardless of `current` (for "Return to stable"), or {}.
static func newest_stable(releases: Variant, need_assets: bool = true) -> Dictionary:
	var list: Array = []
	for rel in eligible(releases, need_assets):
		if str(rel["channel"]) == "stable":
			list.append(rel)
	var sorted: Array = _sort_desc(list)
	return sorted[0] if not sorted.is_empty() else {}


## The newest release to offer (see candidates), or {}.
static func pick_release(releases: Variant, current: String, beta: bool, need_assets: bool = true) -> Dictionary:
	var c: Array = candidates(releases, current, beta, need_assets)
	return c[0] if not c.is_empty() else {}


## Release notes as plain text for a Label: strips common Markdown, caps the length.
static func clean_notes(body: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for line in body.replace("\r\n", "\n").split("\n"):
		var t: String = line.rstrip(" \t")
		var stripped: String = t.lstrip(" \t")
		if stripped.begins_with("#"):
			t = stripped.lstrip("#").strip_edges().to_upper()
		elif stripped.begins_with("- ") or stripped.begins_with("* "):
			t = "• " + stripped.substr(2)
		t = t.replace("**", "").replace("__", "").replace("`", "")
		# [text](url) -> text
		var guard: int = 0
		while guard < 40:
			guard += 1
			var a: int = t.find("](")
			if a < 0:
				break
			var open: int = t.rfind("[", a)
			var close: int = t.find(")", a)
			if open < 0 or close < 0:
				break
			t = t.substr(0, open) + t.substr(open + 1, a - open - 1) + t.substr(close + 1)
		out.append(t)
	var text: String = "\n".join(out).strip_edges()
	if text.length() > UpdateConfig.MAX_NOTES_CHARS:
		text = text.substr(0, UpdateConfig.MAX_NOTES_CHARS) + "\n..."
	return text if text != "" else "No release notes were provided."

# NOVA Swift updater -- semantic version parsing and comparison (semver.org 2.0, build metadata ignored).
#
#   Semver.parse("v1.2.3-beta.1")   -> {"major": 1, "minor": 2, "patch": 3, "pre": ["beta", 1]}  ({} if invalid)
#   Semver.compare("1.2.3", "1.10.0") -> -1 / 0 / 1   (invalid input compares equal: never "newer")
#   Semver.is_newer("1.0.1", "1.0.0") -> true         (both must be valid)
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted


static func _digits(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


static func _ident_ok(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		var ok: bool = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45
		if not ok:
			return false
	return true


## "1.2.3", "v1.2.3", "1.2.3-rc.1", "1.2.3+build" -> parts; {} when it is not a valid semantic version.
static func parse(text: String) -> Dictionary:
	var t: String = text.strip_edges()
	if t.begins_with("v") or t.begins_with("V"):
		t = t.substr(1)
	var plus: int = t.find("+")
	if plus >= 0:
		t = t.substr(0, plus)
	var pre_text: String = ""
	var dash: int = t.find("-")
	if dash >= 0:
		pre_text = t.substr(dash + 1)
		t = t.substr(0, dash)
		if pre_text == "":
			return {}
	var parts: PackedStringArray = t.split(".")
	if parts.size() != 3:
		return {}
	var nums: Array = []
	for p in parts:
		if not _digits(p) or (p.length() > 1 and p.begins_with("0")) or p.length() > 9:
			return {}
		nums.append(int(p))
	var pre: Array = []
	if pre_text != "":
		for id in pre_text.split("."):
			if not _ident_ok(id):
				return {}
			if _digits(id):
				if id.length() > 1 and id.begins_with("0"):
					return {}
				pre.append(int(id))
			else:
				pre.append(id)
	return {"major": nums[0], "minor": nums[1], "patch": nums[2], "pre": pre}


static func is_valid(text: String) -> bool:
	return not parse(text).is_empty()


static func is_prerelease(text: String) -> bool:
	var p: Dictionary = parse(text)
	return not p.is_empty() and not (p["pre"] as Array).is_empty()


static func _cmp_int(a: int, b: int) -> int:
	return -1 if a < b else (1 if a > b else 0)


## Precedence of two parsed versions (semver 2.0 section 11).
static func compare_parsed(a: Dictionary, b: Dictionary) -> int:
	for k in ["major", "minor", "patch"]:
		var c: int = _cmp_int(int(a[k]), int(b[k]))
		if c != 0:
			return c
	var pa: Array = a["pre"]
	var pb: Array = b["pre"]
	if pa.is_empty() and pb.is_empty():
		return 0
	if pa.is_empty():
		return 1      # a release outranks any of its pre-releases
	if pb.is_empty():
		return -1
	var n: int = mini(pa.size(), pb.size())
	for i in n:
		var x: Variant = pa[i]
		var y: Variant = pb[i]
		var xi: bool = x is int
		var yi: bool = y is int
		if xi and yi:
			var c2: int = _cmp_int(int(x), int(y))
			if c2 != 0:
				return c2
		elif xi:
			return -1     # numeric identifiers rank below alphanumeric ones
		elif yi:
			return 1
		else:
			var xs: String = str(x)
			var ys: String = str(y)
			if xs != ys:
				return -1 if xs < ys else 1
	return _cmp_int(pa.size(), pb.size())


## -1 / 0 / 1; an invalid operand makes the result 0 (callers that care use is_newer).
static func compare(a: String, b: String) -> int:
	var pa: Dictionary = parse(a)
	var pb: Dictionary = parse(b)
	if pa.is_empty() or pb.is_empty():
		return 0
	return compare_parsed(pa, pb)


## True only when both are valid and `candidate` strictly outranks `current` (never a downgrade).
static func is_newer(candidate: String, current: String) -> bool:
	var pa: Dictionary = parse(candidate)
	var pb: Dictionary = parse(current)
	if pa.is_empty() or pb.is_empty():
		return false
	return compare_parsed(pa, pb) > 0

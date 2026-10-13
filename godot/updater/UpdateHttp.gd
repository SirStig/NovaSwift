# NOVA Swift updater -- HTTPS transport. A Node (it owns HTTPRequest children and awaits them).
#
# * HTTPS + allow-listed hosts only (UpdateConfig.url_allowed), checked on the first URL AND on every redirect
#   hop: HTTPRequest's own redirect following is turned off (max_redirects = 0) and redirects are followed here.
# * get_bytes(): small bodies (release JSON, manifest, signature).
# * download(): big files with progress, a stall watchdog, retry with backoff and resume (Range) from a .part file.
# * cancel(): aborts whatever is in flight; the .part file stays so a later attempt resumes.
extends Node

const UpdateConfig = preload("res://updater/UpdateConfig.gd")

## (bytes received so far, total expected or 0)
signal progress(done: int, total: int)

const MAX_HOPS := 6
const STALL_SECONDS := 30.0

var _cancelled: bool = false
var _req: HTTPRequest


func cancel() -> void:
	_cancelled = true
	if _req != null and is_instance_valid(_req):
		_req.cancel_request()


func was_cancelled() -> bool:
	return _cancelled


func reset() -> void:
	_cancelled = false


static func user_agent() -> String:
	return "NovaSwift-Updater/%s (%s)" % [UpdateConfig.current_version(), UpdateConfig.platform_key()]


## GET `url` into memory. {ok, code, body, error}. `max_bytes` bounds the body.
func get_bytes(url: String, accept: String, max_bytes: int) -> Dictionary:
	var headers: PackedStringArray = PackedStringArray(["User-Agent: " + user_agent(), "Accept: " + accept])
	if url.begins_with("https://api.github.com/"):
		headers.append("X-GitHub-Api-Version: 2022-11-28")
	return await _fetch(url, headers, "", max_bytes, 0)


## Download `url` to `dest` (an absolute path), resuming `dest + ".part"`. {ok, error, cancelled}.
func download(url: String, dest: String, expected_size: int, attempts: int = 4) -> Dictionary:
	var part: String = dest + ".part"
	var chunk: String = dest + ".chunk"
	var last_error: String = "Download failed."
	for attempt in attempts:
		if _cancelled:
			return {"ok": false, "error": "Cancelled.", "cancelled": true}
		var have: int = _file_size(part)
		if expected_size > 0 and have > expected_size:
			DirAccess.remove_absolute(part)
			have = 0
		if expected_size > 0 and have == expected_size:
			DirAccess.rename_absolute(part, dest)
			return {"ok": true, "error": ""}
		var headers: PackedStringArray = PackedStringArray(["User-Agent: " + user_agent(), "Accept: application/octet-stream"])
		if have > 0:
			headers.append("Range: bytes=%d-" % have)
		DirAccess.remove_absolute(chunk)
		var r: Dictionary = await _fetch(url, headers, chunk, 0, have, expected_size)
		if _cancelled:
			DirAccess.remove_absolute(chunk)
			return {"ok": false, "error": "Cancelled.", "cancelled": true}
		var code: int = int(r.get("code", 0))
		if bool(r.get("ok", false)) and (code == 200 or code == 206):
			if code == 200 or have == 0:
				DirAccess.remove_absolute(part)
				DirAccess.rename_absolute(chunk, part)
			else:
				if not _append(chunk, part):
					last_error = "Could not write the update to disk (is the disk full?)."
					DirAccess.remove_absolute(chunk)
					continue
				DirAccess.remove_absolute(chunk)
			var got: int = _file_size(part)
			if expected_size <= 0 or got == expected_size:
				DirAccess.remove_absolute(dest)
				DirAccess.rename_absolute(part, dest)
				return {"ok": true, "error": ""}
			last_error = "The download ended early (%d of %d bytes)." % [got, expected_size]
		elif code == 416:
			DirAccess.remove_absolute(part)     # the server disagrees with our partial: start over
			last_error = "The partial download was discarded."
		else:
			DirAccess.remove_absolute(chunk)
			last_error = str(r.get("error", "Download failed."))
		if attempt < attempts - 1:
			await get_tree().create_timer(1.5 * float(attempt + 1)).timeout
	return {"ok": false, "error": last_error, "cancelled": false}


func _fetch(url: String, headers: PackedStringArray, file_path: String, max_bytes: int, base: int, total: int = 0) -> Dictionary:
	var cur: String = url
	for hop in MAX_HOPS + 1:
		if not UpdateConfig.url_allowed(cur):
			return {"ok": false, "code": 0, "error": "Blocked a request to an untrusted address."}
		var one: Dictionary = await _once(cur, headers, file_path, max_bytes, base, total)
		var code: int = int(one.get("code", 0))
		if not bool(one.get("ok", false)):
			return one
		if code in [301, 302, 303, 307, 308]:
			if file_path != "":
				DirAccess.remove_absolute(file_path)
			var loc: String = str((one["headers"] as Dictionary).get("location", ""))
			if loc == "":
				return {"ok": false, "code": code, "error": "Redirect without a destination."}
			if loc.begins_with("/"):
				var u: Dictionary = UpdateConfig.parse_url(cur)
				loc = "https://%s%s" % [str(u.get("host", "")), loc]
			cur = loc
			continue
		return one
	return {"ok": false, "code": 0, "error": "Too many redirects."}


func _once(url: String, headers: PackedStringArray, file_path: String, max_bytes: int, base: int, total: int) -> Dictionary:
	var req: HTTPRequest = HTTPRequest.new()
	req.max_redirects = 0
	req.use_threads = true
	req.timeout = 0.0
	if max_bytes > 0:
		req.body_size_limit = max_bytes
	if file_path != "":
		req.download_file = file_path
	add_child(req)
	_req = req
	var st: Dictionary = {"done": false, "result": 0, "code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
	req.request_completed.connect(func(result: int, code: int, hdrs: PackedStringArray, body: PackedByteArray) -> void:
		st["result"] = result
		st["code"] = code
		st["headers"] = hdrs
		st["body"] = body
		st["done"] = true)
	var err: int = req.request(url, headers)
	if err != OK:
		req.queue_free()
		_req = null
		return {"ok": false, "code": 0, "error": "Could not start the request (error %d)." % err}
	var last_bytes: int = -1
	var quiet: float = 0.0
	while not bool(st["done"]):
		await get_tree().create_timer(0.1).timeout
		if _cancelled:
			break
		var got: int = req.get_downloaded_bytes()
		if got != last_bytes:
			last_bytes = got
			quiet = 0.0
			if file_path != "":
				var body_len: int = req.get_body_size()
				progress.emit(base + got, total if total > 0 else (base + body_len if body_len > 0 else 0))
		else:
			quiet += 0.1
		if quiet > STALL_SECONDS and not bool(st["done"]):
			req.cancel_request()
			req.queue_free()
			_req = null
			return {"ok": false, "code": 0, "error": "The connection stalled."}
	if _cancelled and not bool(st["done"]):
		req.cancel_request()
		req.queue_free()
		_req = null
		return {"ok": false, "code": 0, "error": "Cancelled."}
	req.queue_free()
	_req = null
	# max_redirects = 0 reports a redirect as RESULT_REDIRECT_LIMIT_REACHED with the code + headers intact
	# (verified on Godot 4.7.2); _fetch follows it after checking the destination.
	var is_redirect: bool = int(st["result"]) == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED \
		and int(st["code"]) in [301, 302, 303, 307, 308]
	if int(st["result"]) != HTTPRequest.RESULT_SUCCESS and not is_redirect:
		return {"ok": false, "code": int(st["code"]), "error": _result_text(int(st["result"]))}
	var hd: Dictionary = {}
	for line in (st["headers"] as PackedStringArray):
		var i: int = line.find(":")
		if i > 0:
			hd[line.substr(0, i).strip_edges().to_lower()] = line.substr(i + 1).strip_edges()
	var code2: int = int(st["code"])
	var ok: bool = (code2 >= 200 and code2 < 300) or code2 in [301, 302, 303, 307, 308]
	return {"ok": ok, "code": code2, "headers": hd, "body": st["body"],
		"error": "" if ok else "The server answered HTTP %d." % code2}


static func _result_text(r: int) -> String:
	match r:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR:
			return "Could not reach the update server (offline?)."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "A secure connection to the update server could not be established."
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "Could not write the update to disk (is the disk full?)."
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "The server sent more data than expected."
		_:
			return "The download failed (network error %d)." % r


static func _file_size(path: String) -> int:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n: int = f.get_length()
	f.close()
	return n


## Append `src` to `dst` in 1 MiB steps.
static func _append(src: String, dst: String) -> bool:
	var a: FileAccess = FileAccess.open(src, FileAccess.READ)
	var b: FileAccess = FileAccess.open(dst, FileAccess.READ_WRITE)
	if a == null or b == null:
		return false
	b.seek_end()
	while a.get_position() < a.get_length():
		b.store_buffer(a.get_buffer(1048576))
	b.flush()
	return b.get_error() == OK

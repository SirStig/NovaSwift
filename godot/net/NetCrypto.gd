# NOVA Swift -- optional DTLS for the ENet transport ("Encrypt connection").
#
# A hosting game / dedicated server started with encryption owns a self-signed certificate (generated on first use,
# kept in user://net_dtls.key + user://net_dtls.crt). Clients learn the certificate from the server's plain UDP status
# reply (NSB1, field `cert`), remember its SHA-256 fingerprint per "host:port" (trust on first use, NetPrefs.trusted_keys)
# and then connect with that certificate as the ONLY trusted root, so a man in the middle who does not hold the server's
# private key fails the DTLS handshake. A later change of key is refused with a warning until the player accepts it.
#
# Limits: the very first fetch of the certificate is unauthenticated (TOFU), DTLS is per ENet host (a DTLS server
# cannot also accept plain clients), and the password hash / game bytes are encrypted only on connections that use it.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const KEY_PATH := "user://net_dtls.key"
const CERT_PATH := "user://net_dtls.crt"
## Certificate subject / the name clients verify against (clients connect by IP, so the name is fixed, not the host).
const COMMON_NAME := "novaswift-server"


## {key: CryptoKey, cert: X509Certificate, pem: String, fp: String} -- loaded from `dir`, generated if missing or
## unreadable. Empty dictionary when the engine has no TLS support.
static func server_credentials(key_path: String = KEY_PATH, cert_path: String = CERT_PATH) -> Dictionary:
	var key: CryptoKey = CryptoKey.new()
	var cert: X509Certificate = X509Certificate.new()
	if FileAccess.file_exists(key_path) and FileAccess.file_exists(cert_path):
		if key.load(key_path) == OK and cert.load(cert_path) == OK:
			return _pack(key, cert)
	var crypto: Crypto = Crypto.new()
	key = crypto.generate_rsa(2048)
	if key == null:
		return {}
	var now: int = int(Time.get_unix_time_from_system())
	var nb: String = _stamp(now - 86400)
	var na: String = _stamp(now + 86400 * 365 * 20)
	cert = crypto.generate_self_signed_certificate(key, "CN=%s,O=NovaSwift,C=US" % COMMON_NAME, nb, na)
	if cert == null:
		return {}
	key.save(key_path)
	cert.save(cert_path)
	return _pack(key, cert)


static func _pack(key: CryptoKey, cert: X509Certificate) -> Dictionary:
	# save_to_string() returns a PEM with a trailing NUL (an engine warning on conversion); the saved file has none.
	var tmp: String = "user://net_dtls_tmp.crt"
	cert.save(tmp)
	var pem: String = FileAccess.get_file_as_string(tmp)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	return {"key": key, "cert": cert, "pem": pem, "fp": fingerprint(pem)}


static func _stamp(unix: int) -> String:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(unix)
	return "%04d%02d%02d%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]


## Stable SHA-256 of a PEM certificate (whitespace-insensitive), as lower-case hex.
static func fingerprint(pem: String) -> String:
	var t: String = pem.replace("\r", "").replace(String.chr(0), "").strip_edges()
	return t.sha256_text() if t != "" else ""


## Short display form: "AB:CD:EF:..." first 8 bytes.
static func short_fp(fp: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for i in range(0, mini(fp.length(), 16), 2):
		out.append(fp.substr(i, 2).to_upper())
	return ":".join(out)


static func client_options(pem: String) -> TLSOptions:
	var cert: X509Certificate = X509Certificate.new()
	if cert.load_from_string(pem) != OK:
		return null
	return TLSOptions.client(cert, COMMON_NAME)


static func server_options(creds: Dictionary) -> TLSOptions:
	if creds.is_empty():
		return null
	return TLSOptions.server(creds["key"] as CryptoKey, creds["cert"] as X509Certificate)

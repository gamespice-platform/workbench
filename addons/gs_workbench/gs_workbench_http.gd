class_name GSWorkbenchHttp
extends RefCounted

## Mounts a GSWorkbenchApi on a GSHttpServer: bearer-token JSON routes under /api and the static page at /. Off by default.

const CHANNEL := "workbench"
const PAGE := "res://addons/gs_workbench/web/index.html"

var api: GSWorkbenchApi
var server := GSHttpServer.new()
## Override to serve a different page; loaded once at start.
var page_path := PAGE

## Failed tokens per address inside `window_sec` before `lockout_sec` of 429s; 0 disables.
var max_failures := 5
var window_sec := 60.0
var lockout_sec := 300.0
## Override for tests: Callable() -> seconds.
var clock := Callable()

var _page := ""
## id -> {"id", "title", "html", "flag"}; see register_page().
var _pages: Dictionary = {}
## address -> {"times": Array[float] of recent failures, "until": float lockout end}
var _fails: Dictionary = {}


func _init(p_api: GSWorkbenchApi = null) -> void:
	api = p_api if p_api != null else GSWorkbenchApi.new()
	server.route("GET", "/", _on_page)
	server.route("GET", "/index.html", _on_page)
	server.route("POST", "/api", _on_envelope)
	server.route("GET", "/api/pages", _on_pages_list)
	server.route_prefix("GET", "/pages", _on_extra_page)
	for m in ["GET", "PUT", "DELETE", "POST"]:
		server.route_prefix(m, "/api/profiles", _on_profiles)


## Serves [param prefix] (e.g. "/api/things") behind the same bearer token and lockout as the profile routes. [param handler] is `func(actor, req: GSHttpRequest) -> GSResult`, called only when the actor holds [param flag] (checked here; empty skips the check). Register the flag on the token with [method GSWorkbenchApi.add_flag].
func mount_extension(prefix: String, handler: Callable, flag: String = "", methods: PackedStringArray = PackedStringArray(["GET", "POST", "PUT", "DELETE"])) -> void:
	var route := func(req: GSHttpRequest) -> GSHttpResponse:
		var auth: Variant = _gate(req)
		if auth is GSHttpResponse:
			return auth
		if not flag.is_empty() and not api.permits(auth.value, flag):
			return _reply(GSResult.fail(GSError.CODE_FORBIDDEN, "needs the '%s' permission" % flag))
		return _reply(handler.call(auth.value, req))
	for m in methods:
		server.route_prefix(m, prefix, route)


## Adds a page to the registry: served at `/pages/<id>` (like the main page, without a token; it calls its own mounted routes with the token) and listed, with its title, by the token-gated `GET /api/pages` so the main page can link it. [param html] is the whole page. A non-empty [param flag] hides it from tokens lacking that flag. Re-registering an id replaces it. Returns false for an id that is not `[a-z0-9_-]+` or empty html.
func register_page(id: String, title: String, html: String, flag: String = "") -> bool:
	var rx := RegEx.create_from_string("^[a-z0-9_-]+$")
	if rx.search(id) == null or html.is_empty():
		return false
	_pages[id] = {"id": id, "title": title, "html": html, "flag": flag}
	return true


func unregister_page(id: String) -> void:
	_pages.erase(id)


func page_ids() -> PackedStringArray:
	return PackedStringArray(_pages.keys())


## Reads the `workbench:` block of cfg/server.yml (defaults when absent).
static func read_config(path: String = "res://cfg/server.yml") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var res := GSYaml.parse_file(path)
	if not res.ok or not (res.value is Dictionary):
		return {}
	var block: Variant = (res.value as Dictionary).get("workbench", {})
	return block if block is Dictionary else {}


## Starts the HTTP side from the `workbench:` block. Disabled (the default) is a success that opens nothing.
## The admin token comes from [code]token_file[/code] only; there is no environment or command-line path for it.
func start_from_config(cfg: Dictionary) -> GSResult:
	if not bool(cfg.get("enabled", false)):
		return GSResult.success(0)
	var token_file := str(cfg.get("token_file", ""))
	if not token_file.is_empty():
		var tok := GSHttpServer.read_secret_file(token_file)
		if not tok.ok:
			return tok.wrap("workbench token")
		api.set_admin_token(tok.value)
	elif not api.identity.is_valid():
		return GSResult.fail(GSError.CODE_INVALID, "workbench enabled with no token_file and no identity; refusing to start")
	max_failures = int(cfg.get("max_failures", max_failures))
	window_sec = float(cfg.get("window_sec", window_sec))
	lockout_sec = float(cfg.get("lockout_sec", lockout_sec))
	var tls: Dictionary = cfg.get("tls", {}) if cfg.get("tls", {}) is Dictionary else {}
	var native := str(tls.get("mode", "proxy")) == "native"
	var bind := str(cfg.get("bind", GSHttpServer.LOOPBACK))
	if not native and not GSHttpServer.is_loopback(bind) and not bool(cfg.get("allow_plain_remote", false)):
		return GSResult.fail(GSError.CODE_INVALID, "workbench would send its bearer token in clear on a non-loopback address; use native tls or set allow_plain_remote behind a trusted proxy", bind)
	_load_page()
	return server.start(int(cfg.get("port", 8790)), bind,
		str(tls.get("cert", "")) if native else "", str(tls.get("key", "")) if native else "")


## Call from the host's _process.
func poll() -> void:
	server.poll()


func stop() -> void:
	server.stop()


func describe() -> Dictionary:
	return {"server": server.describe(), "page_loaded": not _page.is_empty(), "rate_limit": {"max_failures": max_failures, "window_sec": window_sec, "lockout_sec": lockout_sec, "locked": locked_addresses()}}


## Addresses currently locked out after failed tokens.
func locked_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	var t := _now()
	for a in _fails:
		if float(_fails[a]["until"]) > t:
			out.append(a)
	return out


## Lifts a lockout, for an operator who locked themselves out.
func clear_lockout(address: String) -> void:
	_fails.erase(address)


func _now() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_ticks_msec() / 1000.0


# Returns a refusal response, or null when the token is good. Counts failures per address.
func _gate(req: GSHttpRequest) -> Variant:
	var addr := req.remote_address
	var t := _now()
	var rec: Dictionary = _fails.get(addr, {"times": [], "until": 0.0})
	if max_failures > 0 and float(rec["until"]) > t:
		var r := GSHttpResponse.json(GSWorkbenchApi.to_reply(GSResult.fail(GSError.CODE_FORBIDDEN, "too many failed tokens; try again later")), 429)
		r.headers["Retry-After"] = str(int(ceil(float(rec["until"]) - t)))
		return r
	var auth := api.authenticate(req.bearer_token())
	if auth.ok:
		_fails.erase(addr)
		return auth
	if max_failures > 0:
		var times: Array = (rec["times"] as Array).filter(func(x: float) -> bool: return t - x < window_sec)
		times.append(t)
		rec["times"] = times
		if times.size() >= max_failures:
			rec["until"] = t + lockout_sec
			rec["times"] = []
			GSLog.warn(CHANNEL, "address locked out after failed tokens", {"address": addr, "seconds": lockout_sec})
		_fails[addr] = rec
	return _unauthorized()


func _load_page() -> void:
	_page = FileAccess.get_file_as_string(page_path) if FileAccess.file_exists(page_path) else ""
	if _page.is_empty():
		GSLog.warn(CHANNEL, "workbench page missing; the API still works", {"path": page_path})


func _on_page(_req: GSHttpRequest) -> GSHttpResponse:
	if _page.is_empty():
		return GSHttpResponse.error(404, "no page installed")
	var r := GSHttpResponse.html(_page)
	r.headers["Cache-Control"] = "no-store"
	r.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
	r.headers["Referrer-Policy"] = "no-referrer"
	return r


func _on_extra_page(req: GSHttpRequest) -> GSHttpResponse:
	var id := req.rest.trim_prefix("/")
	if not _pages.has(id):
		return GSHttpResponse.error(404, "no such page")
	var r := GSHttpResponse.html(str(_pages[id]["html"]))
	r.headers["Cache-Control"] = "no-store"
	r.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
	r.headers["Referrer-Policy"] = "no-referrer"
	return r


func _on_pages_list(req: GSHttpRequest) -> GSHttpResponse:
	var auth: Variant = _gate(req)
	if auth is GSHttpResponse:
		return auth
	var out: Array = []
	for id in _pages:
		var pg: Dictionary = _pages[id]
		if str(pg["flag"]).is_empty() or api.permits(auth.value, str(pg["flag"])):
			out.append({"id": id, "title": pg["title"], "url": "/pages/" + id})
	return _reply(GSResult.success(out))


# Generic envelope: POST /api with the request object, the reply object back.
func _on_envelope(req: GSHttpRequest) -> GSHttpResponse:
	var auth: Variant = _gate(req)
	if auth is GSHttpResponse:
		return auth
	var body := req.json_body()
	if not body.ok or not (body.value is Dictionary):
		return _reply(GSResult.fail(GSError.CODE_INVALID, "body must be a JSON object"))
	return _reply(api.handle(auth.value, body.value))


# REST sugar over the same ops: /api/profiles[/kind[/id[/key]]] and POST /api/profiles/{save,add,delete}/kind/id.
func _on_profiles(req: GSHttpRequest) -> GSHttpResponse:
	var auth: Variant = _gate(req)
	if auth is GSHttpResponse:
		return auth
	var seg := PackedStringArray()
	for s in req.rest.split("/", false):
		seg.append(s)
	var body: Dictionary = {}
	if not req.body.is_empty():
		var parsed := req.json_body()
		if not parsed.ok or not (parsed.value is Dictionary):
			return _reply(GSResult.fail(GSError.CODE_INVALID, "body must be a JSON object"))
		body = parsed.value
	var op := {}
	match req.method:
		"GET":
			if seg.size() > 2:
				return GSHttpResponse.error(404)
			op = {"op": "list" if seg.size() < 2 else "get", "kind": _at(seg, 0), "id": _at(seg, 1)}
		"PUT":
			if seg.size() != 3 or not body.has("value"):
				return _reply(GSResult.fail(GSError.CODE_INVALID, "PUT /api/profiles/<kind>/<id>/<key> with {\"value\": ...}"))
			op = {"op": "set", "kind": seg[0], "id": seg[1], "key": seg[2], "value": body["value"]}
		"DELETE":
			if seg.size() < 2 or seg.size() > 3:
				return GSHttpResponse.error(404)
			op = {"op": "reset_key" if seg.size() == 3 else "reset", "kind": seg[0], "id": seg[1], "key": _at(seg, 2)}
		"POST":
			if seg.size() != 3 or not ["save", "add", "delete"].has(seg[0]):
				return GSHttpResponse.error(404)
			op = {"op": seg[0], "kind": seg[1], "id": seg[2]}
			if seg[0] == "add" and body.has("value"):
				op["value"] = body["value"]
	return _reply(api.handle(auth.value, op))


static func _at(seg: PackedStringArray, i: int) -> String:
	return seg[i] if i < seg.size() else ""


func _unauthorized() -> GSHttpResponse:
	var r := GSHttpResponse.json(GSWorkbenchApi.to_reply(GSResult.fail(GSError.CODE_AUTH, "a valid bearer token is required")), 401)
	r.headers["WWW-Authenticate"] = "Bearer"
	return r


func _reply(res: GSResult) -> GSHttpResponse:
	var status := 200
	if not res.ok:
		match res.error.code:
			GSError.CODE_AUTH: status = 401
			GSError.CODE_FORBIDDEN: status = 403
			GSError.CODE_CONFLICT: status = 409
			GSError.CODE_INTERNAL, GSError.CODE_IO: status = 500
			_: status = 400
	var r := GSHttpResponse.json(GSWorkbenchApi.to_reply(res), status)
	r.headers["Cache-Control"] = "no-store"
	return r

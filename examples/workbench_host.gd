extends Node

## Demo host: serves the workbench page on loopback with sample profiles until quit. Token is "s3cret".
## Run: godot --headless --path . res://examples/workbench_host.tscn -- 8791

const BASE := "user://workbench_host"

var _http: GSWorkbenchHttp


func _ready() -> void:
	GSLog.set_level(GSLog.Level.WARN)
	DirAccess.make_dir_recursive_absolute(BASE.path_join("addons/gs-npc/npc"))
	var f := FileAccess.open(BASE.path_join("addons/gs-npc/npc/zombie.yml"), FileAccess.WRITE)
	f.store_string("health: 50\nspeed: 2.5\n")
	f.close()
	var s := GSProfileSet.create("gs-npc", "mygame", "npc", [
		GSProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
		GSProfileSet.field("speed", "float", 3.0, {"min": 0.0, "max": 50.0}),
		GSProfileSet.field("mode", "string", "melee", {"enum": ["melee", "ranged"]}),
		GSProfileSet.field("aggressive", "bool", true),
	])
	s.roots = PackedStringArray([BASE])
	s.override_prefix = "wbh"
	var api := GSWorkbenchApi.new()
	api.runtime.save_root = BASE
	api.add_set(s)
	api.set_admin_token("s3cret")
	_http = GSWorkbenchHttp.new(api)
	var args := OS.get_cmdline_user_args()
	var port := int(args[0]) if args.size() > 0 else 8791
	var res := _http.server.start(port)
	if not res.ok:
		printerr("start failed: ", res.error.message)
		get_tree().quit(1)
		return
	_http._load_page()
	print("workbench host on ", port)


func _process(_d: float) -> void:
	_http.poll()

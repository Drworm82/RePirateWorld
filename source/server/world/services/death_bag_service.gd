extends RefCounted

## PirateWorld PoC-01: persistent physical loot.
## Server-authoritative storage and pickup validation.

const PICKUP_DISTANCE: float = 96.0

var db
var world_server

func _init(_db: SQLite, _world_server) -> void:
\tdb = _db
\tworld_server = _world_server


func spawn_from_player(instance, player) -> Dictionary:
\tif instance == null or player == null or player.player_resource == null:
\t\treturn {"ok": false, "reason": "invalid_player"}

\tvar contents: Dictionary = Inventory.normalize(player.player_resource.inventory).duplicate(true)
\tif contents.is_empty():
\t\treturn {"ok": false, "reason": "empty_inventory"}

\tvar instance_name: String = str(instance.instance_resource.instance_name)
\tvar created_at_ms: int = int(Time.get_unix_time_from_system() * 1000.0)
\tdb.query_with_bindings(
\t\t"INSERT INTO death_bags(instance_name, x, y, owner_id, contents_json, created_at_ms) VALUES(?, ?, ?, ?, ?, ?);",
\t\t[
\t\t\tinstance_name,
\t\t\tplayer.global_position.x,
\t\t\tplayer.global_position.y,
\t\t\tplayer.player_resource.player_id,
\t\t\tJSON.stringify(contents),
\t\t\tcreated_at_ms,
\t\t]
\t)
\tdb.query("SELECT last_insert_rowid() AS bag_id;")
\tif db.query_result.is_empty():
\t\treturn {"ok": false, "reason": "database_insert_failed"}

\tvar bag_id: int = int(db.query_result[0].get("bag_id", 0))
\tplayer.player_resource.inventory.clear()
\tworld_server.database.save_player(player.player_resource)

\tvar bag: Dictionary = {
\t\t"bag_id": bag_id,
\t\t"instance_name": instance_name,
\t\t"position": player.global_position,
\t\t"owner_id": player.player_resource.player_id,
\t\t"contents": contents,
\t\t"created_at_ms": created_at_ms,
\t}
\t_broadcast(instance, &"pirateworld.death_bag.spawn", bag)
\treturn {"ok": true, "bag": bag}


func list_for_instance(instance_name: String) -> Array:
\tvar result: Array = []
\tdb.query_with_bindings(
\t\t"SELECT bag_id, instance_name, x, y, owner_id, contents_json, created_at_ms FROM death_bags WHERE instance_name=? ORDER BY bag_id ASC;",
\t\t[instance_name]
\t)
\tfor row: Dictionary in db.query_result:
\t\tvar contents_v: Variant = JSON.parse_string(str(row.get("contents_json", "{}")))
\t\tvar contents: Dictionary = contents_v if contents_v is Dictionary else {}
\t\tresult.append({
\t\t\t"bag_id": int(row.get("bag_id", 0)),
\t\t\t"instance_name": str(row.get("instance_name", "")),
\t\t\t"position": Vector2(float(row.get("x", 0.0)), float(row.get("y", 0.0))),
\t\t\t"owner_id": int(row.get("owner_id", 0)),
\t\t\t"contents": contents,
\t\t\t"created_at_ms": int(row.get("created_at_ms", 0)),
\t\t})
\treturn result


func pickup(peer_id: int, instance, bag_id: int) -> Dictionary:
\tif instance == null or bag_id <= 0:
\t\treturn {"ok": false, "reason": "bad_args"}

\tvar player = instance.get_player(peer_id)
\tif player == null or player.player_resource == null:
\t\treturn {"ok": false, "reason": "player_not_found"}

\tdb.query_with_bindings(
\t\t"SELECT bag_id, instance_name, x, y, owner_id, contents_json FROM death_bags WHERE bag_id=?;",
\t\t[bag_id]
\t)
\tif db.query_result.is_empty():
\t\treturn {"ok": false, "reason": "not_found"}

\tvar row: Dictionary = db.query_result[0]
\tif str(row.get("instance_name", "")) != str(instance.instance_resource.instance_name):
\t\treturn {"ok": false, "reason": "wrong_instance"}

\tvar bag_position := Vector2(float(row.get("x", 0.0)), float(row.get("y", 0.0)))
\tif player.global_position.distance_to(bag_position) > PICKUP_DISTANCE:
\t\treturn {"ok": false, "reason": "too_far"}

\tvar contents_v: Variant = JSON.parse_string(str(row.get("contents_json", "{}")))
\tvar contents: Dictionary = contents_v if contents_v is Dictionary else {}
\tfor slot_uid in contents:
\t\tvar slot: Dictionary = contents[slot_uid]
\t\tvar item_id: int = int(slot.get("id", 0))
\t\tvar amount: int = int(slot.get("a", 0))
\t\tif item_id > 0 and amount > 0:
\t\t\tInventory.add_item(player.player_resource.inventory, item_id, amount)

\tdb.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
\tworld_server.database.save_player(player.player_resource)
\t_broadcast(instance, &"pirateworld.death_bag.remove", {"bag_id": bag_id})
\treturn {
\t\t"ok": true,
\t\t"bag_id": bag_id,
\t\t"inventory": player.player_resource.inventory,
\t}


func _broadcast(instance, type: StringName, payload: Dictionary) -> void:
\tif instance == null:
\t\treturn
\tfor peer_id: int in instance.connected_peers:
\t\tWorldServer.curr.data_push.rpc_id(peer_id, type, payload)

extends RefCounted

## PirateWorld PoC-02: persistent physical loot with partial looting.
## Server-authoritative storage, access locking and per-slot pickup.

const PICKUP_DISTANCE: float = 96.0
const ACCESS_TIMEOUT_MS: int = 60_000

var db
var world_server
var _locks: Dictionary = {}

func _init(database, server) -> void:
    db = database
    world_server = server


func spawn_from_player(instance, player):
    if instance == null or player == null or player.player_resource == null:
        return {"ok": false, "reason": "invalid_player"}

    var contents = player.player_resource.inventory.duplicate(true)
    if contents.is_empty():
        return {"ok": false, "reason": "empty_inventory"}

    var instance_name = str(instance.instance_resource.instance_name)
    var created_at_ms = int(Time.get_unix_time_from_system() * 1000.0)

    db.query_with_bindings(
        "INSERT INTO death_bags(instance_name, x, y, owner_id, contents_json, created_at_ms) VALUES(?, ?, ?, ?, ?, ?);",
        [
            instance_name,
            player.global_position.x,
            player.global_position.y,
            player.player_resource.player_id,
            JSON.stringify(contents),
            created_at_ms,
        ]
    )

    db.query("SELECT last_insert_rowid() AS bag_id;")
    if db.query_result.is_empty():
        return {"ok": false, "reason": "database_insert_failed"}

    var bag_id = int(db.query_result[0].get("bag_id", 0))

    player.player_resource.inventory.clear()
    world_server.database.save_player(player.player_resource)

    var bag = {
        "bag_id": bag_id,
        "instance_name": instance_name,
        "position": player.global_position,
        "owner_id": player.player_resource.player_id,
        "owner_name": player.player_resource.display_name,
        "contents": contents,
        "created_at_ms": created_at_ms,
    }

    _broadcast(instance, "pirateworld.death_bag.spawn", bag)
    return {"ok": true, "bag": bag}


func list_for_instance(instance_name):
    var result = []

    db.query_with_bindings(
        "SELECT bag_id, instance_name, x, y, owner_id, contents_json, created_at_ms FROM death_bags WHERE instance_name=? ORDER BY bag_id ASC;",
        [instance_name]
    )

    for row in db.query_result:
        var contents_value = JSON.parse_string(str(row.get("contents_json", "{}")))
        var contents = {}
        if contents_value is Dictionary:
            contents = contents_value

        result.append({
            "bag_id": int(row.get("bag_id", 0)),
            "instance_name": str(row.get("instance_name", "")),
            "position": Vector2(float(row.get("x", 0.0)), float(row.get("y", 0.0))),
            "owner_id": int(row.get("owner_id", 0)),
            "contents": contents,
            "created_at_ms": int(row.get("created_at_ms", 0)),
        })

    return result


func open(peer_id, instance, bag_id):
    if instance == null or bag_id <= 0:
        return {"ok": false, "reason": "bad_args"}

    var player = instance.get_player(peer_id)
    if player == null or player.player_resource == null:
        return {"ok": false, "reason": "player_not_found"}

    var bag = _load_bag(bag_id)
    if bag.is_empty():
        return {"ok": false, "reason": "not_found"}

    if str(bag.get("instance_name", "")) != str(instance.instance_resource.instance_name):
        return {"ok": false, "reason": "wrong_instance"}

    if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
        return {"ok": false, "reason": "too_far"}

    if not _claim_lock(bag_id, peer_id):
        return {"ok": false, "reason": "in_use"}

    return {
        "ok": true,
        "bag_id": bag_id,
        "owner_id": bag.owner_id,
        "owner_name": bag.owner_name,
        "contents": bag.contents,
    }


func loot(peer_id, instance, bag_id, slot_uid: String):
    if instance == null or bag_id <= 0 or slot_uid.is_empty():
        return {"ok": false, "reason": "bad_args"}

    var player = instance.get_player(peer_id)
    if player == null or player.player_resource == null:
        return {"ok": false, "reason": "player_not_found"}

    if not _owns_lock(bag_id, peer_id):
        return {"ok": false, "reason": "not_open"}

    var bag = _load_bag(bag_id)
    if bag.is_empty():
        _release_lock(bag_id)
        return {"ok": false, "reason": "not_found"}

    if str(bag.get("instance_name", "")) != str(instance.instance_resource.instance_name):
        _release_lock(bag_id)
        return {"ok": false, "reason": "wrong_instance"}

    if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
        _release_lock(bag_id)
        return {"ok": false, "reason": "too_far"}

    var contents: Dictionary = bag.contents
    if not contents.has(slot_uid):
        return {"ok": false, "reason": "slot_gone", "contents": contents}

    var slot = contents[slot_uid]
    if not slot is Dictionary:
        return {"ok": false, "reason": "invalid_slot", "contents": contents}

    var item_id := int(slot.get("id", 0))
    var amount := int(slot.get("a", 0))
    if item_id <= 0 or amount <= 0:
        return {"ok": false, "reason": "invalid_slot", "contents": contents}

    _add_item(player.player_resource.inventory, item_id, amount)
    contents.erase(slot_uid)
    _touch_lock(bag_id, peer_id)

    if contents.is_empty():
        db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
        world_server.database.save_player(player.player_resource)
        _release_lock(bag_id)
        _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})
        return {
            "ok": true,
            "bag_id": bag_id,
            "slot_uid": slot_uid,
            "emptied": true,
            "contents": {},
        }

    db.query_with_bindings(
        "UPDATE death_bags SET contents_json=? WHERE bag_id=?;",
        [JSON.stringify(contents), bag_id]
    )
    world_server.database.save_player(player.player_resource)

    _broadcast(instance, "pirateworld.death_bag.changed", {
        "bag_id": bag_id,
        "contents": contents,
    })

    return {
        "ok": true,
        "bag_id": bag_id,
        "slot_uid": slot_uid,
        "emptied": false,
        "contents": contents,
    }


func loot_all(peer_id, instance, bag_id):
    if instance == null or bag_id <= 0:
        return {"ok": false, "reason": "bad_args"}

    var player = instance.get_player(peer_id)
    if player == null or player.player_resource == null:
        return {"ok": false, "reason": "player_not_found"}

    if not _owns_lock(bag_id, peer_id):
        return {"ok": false, "reason": "not_open"}

    var bag = _load_bag(bag_id)
    if bag.is_empty():
        _release_lock(bag_id)
        return {"ok": false, "reason": "not_found"}

    if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
        _release_lock(bag_id)
        return {"ok": false, "reason": "too_far"}

    var contents: Dictionary = bag.contents
    for slot_uid in contents.keys():
        var slot = contents[slot_uid]
        if slot is Dictionary:
            var item_id := int(slot.get("id", 0))
            var amount := int(slot.get("a", 0))
            if item_id > 0 and amount > 0:
                _add_item(player.player_resource.inventory, item_id, amount)

    db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
    world_server.database.save_player(player.player_resource)
    _release_lock(bag_id)
    _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})

    return {
        "ok": true,
        "bag_id": bag_id,
        "emptied": true,
        "contents": {},
    }


func _load_bag(bag_id: int) -> Dictionary:
    db.query_with_bindings(
        "SELECT bag_id, instance_name, x, y, owner_id, contents_json FROM death_bags WHERE bag_id=?;",
        [bag_id]
    )

    if db.query_result.is_empty():
        return {}

    var row = db.query_result[0]
    var contents_value = JSON.parse_string(str(row.get("contents_json", "{}")))
    var contents: Dictionary = {}
    if contents_value is Dictionary:
        contents = contents_value

    return {
        "bag_id": int(row.get("bag_id", 0)),
        "instance_name": str(row.get("instance_name", "")),
        "position": Vector2(float(row.get("x", 0.0)), float(row.get("y", 0.0))),
        "owner_id": int(row.get("owner_id", 0)),
        "owner_name": world_server.database.store.get_player_display_name(int(row.get("owner_id", 0))),
        "contents": contents,
    }


func close(peer_id, instance, bag_id: int):
    if instance == null or bag_id <= 0:
        return {"ok": false, "reason": "bad_args"}

    var player = instance.get_player(peer_id)
    if player == null or player.player_resource == null:
        return {"ok": false, "reason": "player_not_found"}

    if not _owns_lock(bag_id, peer_id):
        return {"ok": false, "reason": "not_open"}

    _release_lock(bag_id)
    return {"ok": true, "bag_id": bag_id}


func _claim_lock(bag_id: int, peer_id: int) -> bool:
    _expire_lock_if_needed(bag_id)
    if _locks.has(bag_id):
        return false
    _locks[bag_id] = {
        "peer_id": peer_id,
        "last_action_ms": Time.get_ticks_msec(),
    }
    return true


func _owns_lock(bag_id: int, peer_id: int) -> bool:
    _expire_lock_if_needed(bag_id)
    return _locks.has(bag_id) and int(_locks[bag_id].get("peer_id", -1)) == peer_id


func _touch_lock(bag_id: int, peer_id: int) -> void:
    if _owns_lock(bag_id, peer_id):
        _locks[bag_id]["last_action_ms"] = Time.get_ticks_msec()


func _expire_lock_if_needed(bag_id: int) -> void:
    if not _locks.has(bag_id):
        return
    var last_action_ms := int(_locks[bag_id].get("last_action_ms", 0))
    if Time.get_ticks_msec() - last_action_ms >= ACCESS_TIMEOUT_MS:
        _locks.erase(bag_id)


func _release_lock(bag_id: int) -> void:
    _locks.erase(bag_id)


func _broadcast(instance, message_type, payload): 
    if instance == null:
        return

    for peer_id in instance.connected_peers:
        world_server.data_push.rpc_id(peer_id, message_type, payload)


func _add_item(inventory, item_id, amount): 
    for slot_uid in inventory:
        var slot = inventory[slot_uid]

        if slot is Dictionary and int(slot.get("id", 0)) == item_id:
            slot["a"] = int(slot.get("a", 0)) + amount
            inventory[slot_uid] = slot
            return

    var new_slot_id = "death_bag_" + str(Time.get_ticks_usec())
    inventory[new_slot_id] = {
        "id": item_id,
        "a": amount,
    }

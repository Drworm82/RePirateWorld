extends RefCounted

## PirateWorld PoC-02: persistent physical loot with partial looting.
## Server-authoritative storage, access locking and per-slot pickup.

const PICKUP_DISTANCE: float = 96.0
const ACCESS_TIMEOUT_MS: int = 60_000
const FLOATING_DURATION_MS: int = 2 * 60 * 1000
const SUNKEN_DURATION_MS: int = 5 * 60 * 1000
const STATE_FLOATING: String = "floating"
const STATE_SUNK: String = "sunk"
# PoC capacity: 36 inventory slots, matching the current 6-column bag presentation.
const INVENTORY_SLOT_CAPACITY: int = 36
# PoC capacity: 36 inventory slots, matching the current 6-column bag presentation.
const INVENTORY_SLOT_CAPACITY: int = 36

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
        "state": STATE_FLOATING,
        "contents": contents,
        "created_at_ms": created_at_ms,
    }

    _broadcast(instance, "pirateworld.death_bag.spawn", bag)
    return {"ok": true, "bag": bag}


func list_for_instance(instance_name):
    var result = []

    db.query_with_bindings(
        "SELECT bag_id, instance_name, x, y, owner_id, contents_json, created_at_ms, state, sunk_at_ms FROM death_bags WHERE instance_name=? ORDER BY bag_id ASC;",
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
            "owner_name": world_server.database.store.get_player_display_name(int(row.get("owner_id", 0))),
            "state": str(row.get("state", STATE_FLOATING)),
            "contents": contents,
            "created_at_ms": int(row.get("created_at_ms", 0)),
            "sunk_at_ms": int(row.get("sunk_at_ms", 0)),
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

    if str(bag.get("state", STATE_FLOATING)) != STATE_FLOATING:
        return {"ok": false, "reason": "sunk"}

    if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
        return {"ok": false, "reason": "too_far"}

    if not _owns_lock(bag_id, peer_id):
        if not _claim_lock(bag_id, peer_id):
            return {"ok": false, "reason": "in_use"}

    return {
        "ok": true,
        "bag_id": bag_id,
        "owner_id": bag.owner_id,
        "owner_name": bag.owner_name,
        "state": bag.state,
        "contents": bag.contents,
    }


func open_sunk(peer_id, instance, bag_id: int) -> Dictionary:
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
    if str(bag.get("state", STATE_FLOATING)) != STATE_SUNK:
        return {"ok": false, "reason": "not_sunk"}
    if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
        return {"ok": false, "reason": "too_far"}
    if not _owns_lock(bag_id, peer_id):
        if not _claim_lock(bag_id, peer_id, "sunk"):
            return {"ok": false, "reason": "in_use"}

    return {
        "ok": true,
        "bag_id": bag_id,
        "owner_id": bag.owner_id,
        "owner_name": bag.owner_name,
        "state": bag.state,
        "contents": bag.contents,
        "access": "simulated_ad",
    }


func loot(peer_id, instance, bag_id, slot_uid: String):
    if _lock_mode(bag_id) == "sunk":
        return _loot_with_mode(peer_id, instance, bag_id, slot_uid, STATE_SUNK)

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

    if str(bag.get("state", STATE_FLOATING)) != STATE_FLOATING:
        _release_lock(bag_id)
        return {"ok": false, "reason": "sunk"}

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

    var moved := _add_item(player.player_resource.inventory, item_id, amount)
    if moved <= 0:
        return {"ok": false, "reason": "inventory_full", "contents": contents}

    var remaining := amount - moved
    if remaining <= 0:
        contents.erase(slot_uid)
    else:
        slot["a"] = remaining
        contents[slot_uid] = slot

    _touch_lock(bag_id, peer_id)
    world_server.database.save_player(player.player_resource)

    if contents.is_empty():
        db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
        _release_lock(bag_id)
        _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})
        return {"ok": true, "bag_id": bag_id, "slot_uid": slot_uid, "moved": moved, "remaining": 0, "emptied": true, "contents": {}}

    db.query_with_bindings("UPDATE death_bags SET contents_json=? WHERE bag_id=?;", [JSON.stringify(contents), bag_id])
    _broadcast(instance, "pirateworld.death_bag.changed", {"bag_id": bag_id, "contents": contents})
    return {"ok": true, "bag_id": bag_id, "slot_uid": slot_uid, "moved": moved, "remaining": remaining, "emptied": false, "contents": contents}


func loot_sunk(peer_id, instance, bag_id, slot_uid: String) -> Dictionary:
    return _loot_with_mode(peer_id, instance, bag_id, slot_uid, STATE_SUNK)


func loot_all_sunk(peer_id, instance, bag_id: int) -> Dictionary:
    if _lock_mode(bag_id) != "sunk":
        return {"ok": false, "reason": "not_open"}

    var bag = _load_bag(bag_id)
    if bag.is_empty():
        _release_lock(bag_id)
        return {"ok": false, "reason": "not_found"}
    if str(bag.get("state", STATE_FLOATING)) != STATE_SUNK:
        _release_lock(bag_id)
        return {"ok": false, "reason": "not_sunk"}
    if instance == null or player_distance(instance, peer_id, bag) > PICKUP_DISTANCE:
        _release_lock(bag_id)
        return {"ok": false, "reason": "too_far"}

    var player = instance.get_player(peer_id)
    if player == null or player.player_resource == null:
        _release_lock(bag_id)
        return {"ok": false, "reason": "player_not_found"}

    var contents: Dictionary = bag.contents
    var moved_total := 0
    for slot_uid in contents.keys():
        if not contents.has(slot_uid):
            continue
        var slot = contents[slot_uid]
        if not slot is Dictionary:
            continue
        var item_id := int(slot.get("id", 0))
        var amount := int(slot.get("a", 0))
        if item_id <= 0 or amount <= 0:
            continue
        var moved := _add_item(player.player_resource.inventory, item_id, amount)
        moved_total += moved
        var remaining := amount - moved
        if remaining <= 0:
            contents.erase(slot_uid)
        else:
            slot["a"] = remaining
            contents[slot_uid] = slot

    if moved_total <= 0:
        return {"ok": false, "reason": "inventory_full", "contents": contents}

    _touch_lock(bag_id, peer_id)
    world_server.database.save_player(player.player_resource)

    if contents.is_empty():
        db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
        _release_lock(bag_id)
        _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})
        return {"ok": true, "bag_id": bag_id, "moved": moved_total, "emptied": true, "contents": {}}

    db.query_with_bindings("UPDATE death_bags SET contents_json=? WHERE bag_id=?;", [JSON.stringify(contents), bag_id])
    _broadcast(instance, "pirateworld.death_bag.changed", {"bag_id": bag_id, "contents": contents})
    return {"ok": true, "bag_id": bag_id, "moved": moved_total, "emptied": false, "contents": contents}


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

    if str(bag.get("state", STATE_FLOATING)) != STATE_FLOATING:
        _release_lock(bag_id)
        return {"ok": false, "reason": "sunk"}

    if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
        _release_lock(bag_id)
        return {"ok": false, "reason": "too_far"}

    var contents: Dictionary = bag.contents
    var moved_total := 0
    for slot_uid in contents.keys():
        if not contents.has(slot_uid):
            continue
        var slot = contents[slot_uid]
        if not slot is Dictionary:
            continue
        var item_id := int(slot.get("id", 0))
        var amount := int(slot.get("a", 0))
        if item_id <= 0 or amount <= 0:
            continue
        var moved := _add_item(player.player_resource.inventory, item_id, amount)
        moved_total += moved
        var remaining := amount - moved
        if remaining <= 0:
            contents.erase(slot_uid)
        else:
            slot["a"] = remaining
            contents[slot_uid] = slot

    if moved_total <= 0:
        return {"ok": false, "reason": "inventory_full", "contents": contents}

    _touch_lock(bag_id, peer_id)
    world_server.database.save_player(player.player_resource)

    if contents.is_empty():
        db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
        _release_lock(bag_id)
        _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})
        return {"ok": true, "bag_id": bag_id, "moved": moved_total, "emptied": true, "contents": {}}

    db.query_with_bindings("UPDATE death_bags SET contents_json=? WHERE bag_id=?;", [JSON.stringify(contents), bag_id])
    _broadcast(instance, "pirateworld.death_bag.changed", {"bag_id": bag_id, "contents": contents})
    return {"ok": true, "bag_id": bag_id, "moved": moved_total, "emptied": false, "contents": contents}


func _load_bag(bag_id: int) -> Dictionary:
    db.query_with_bindings(
        "SELECT bag_id, instance_name, x, y, owner_id, contents_json, state, sunk_at_ms FROM death_bags WHERE bag_id=?;",
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
        "state": str(row.get("state", STATE_FLOATING)),
        "sunk_at_ms": int(row.get("sunk_at_ms", 0)),
        "contents": contents,
    }


func tick_lifecycle() -> void:
    var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
    db.query("SELECT bag_id, instance_name, state, created_at_ms, sunk_at_ms FROM death_bags;")
    for row: Dictionary in db.query_result:
        var bag_id := int(row.get("bag_id", 0))
        var instance_name := str(row.get("instance_name", ""))
        var state := str(row.get("state", STATE_FLOATING))
        var created_at_ms := int(row.get("created_at_ms", 0))
        var sunk_at_ms := int(row.get("sunk_at_ms", 0))

        if state == STATE_FLOATING and now_ms - created_at_ms >= FLOATING_DURATION_MS:
            db.query_with_bindings(
                "UPDATE death_bags SET state=?, sunk_at_ms=? WHERE bag_id=?;",
                [STATE_SUNK, now_ms, bag_id]
            )
            _release_lock(bag_id)
            _broadcast_state(instance_name, bag_id, STATE_SUNK)
        elif state == STATE_SUNK and sunk_at_ms > 0 and now_ms - sunk_at_ms >= SUNKEN_DURATION_MS:
            db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
            _release_lock(bag_id)
            _broadcast_remove(instance_name, bag_id)


func force_sink_latest(instance_name: String) -> Dictionary:
    if instance_name.is_empty():
        return {"ok": false, "reason": "instance_required"}

    db.query_with_bindings(
        "SELECT bag_id FROM death_bags WHERE instance_name=? ORDER BY bag_id DESC LIMIT 1;",
        [instance_name]
    )
    if db.query_result.is_empty():
        return {"ok": false, "reason": "not_found"}

    var bag_id := int(db.query_result[0].get("bag_id", 0))
    if bag_id <= 0:
        return {"ok": false, "reason": "not_found"}

    return force_sink(bag_id)


func force_sink(bag_id: int) -> Dictionary:
    var bag := _load_bag(bag_id)
    if bag.is_empty():
        return {"ok": false, "reason": "not_found"}
    if bag.state == STATE_SUNK:
        return {"ok": true, "bag_id": bag_id, "state": STATE_SUNK}
    var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
    db.query_with_bindings(
        "UPDATE death_bags SET state=?, sunk_at_ms=? WHERE bag_id=?;",
        [STATE_SUNK, now_ms, bag_id]
    )
    _release_lock(bag_id)
    _broadcast_state(str(bag.get("instance_name", "")), bag_id, STATE_SUNK)
    return {"ok": true, "bag_id": bag_id, "state": STATE_SUNK}


func _broadcast_state(instance_name: String, bag_id: int, state: String) -> void:
    var instance = _find_instance(instance_name)
    if instance == null:
        return
    _broadcast(instance, "pirateworld.death_bag.state", {
        "bag_id": bag_id,
        "state": state,
    })


func _broadcast_remove(instance_name: String, bag_id: int) -> void:
    var instance = _find_instance(instance_name)
    if instance == null:
        return
    _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})


func _find_instance(instance_name: String):
    if world_server == null or world_server.instance_manager == null:
        return null
    for instance_resource in world_server.instance_manager.instance_collection.values():
        for instance in instance_resource.charged_instances:
            if str(instance.instance_resource.instance_name) == instance_name:
                return instance
    return null


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


func _claim_lock(bag_id: int, peer_id: int, mode: String = "surface") -> bool:
    _expire_lock_if_needed(bag_id)
    if _locks.has(bag_id):
        return false
    _locks[bag_id] = {
        "peer_id": peer_id,
        "mode": mode,
        "last_action_ms": Time.get_ticks_msec(),
    }
    return true


func _lock_mode(bag_id: int) -> String:
    if not _locks.has(bag_id):
        return ""
    return str(_locks[bag_id].get("mode", "surface"))


func _loot_with_mode(peer_id, instance, bag_id, slot_uid: String, expected_state: String) -> Dictionary:
    if instance == null or bag_id <= 0 or slot_uid.is_empty():
        return {"ok": false, "reason": "bad_args"}
    if _lock_mode(bag_id) != "sunk":
        return {"ok": false, "reason": "not_open"}

    var player = instance.get_player(peer_id)
    if player == null or player.player_resource == null:
        return {"ok": false, "reason": "player_not_found"}
    var bag = _load_bag(bag_id)
    if bag.is_empty():
        _release_lock(bag_id)
        return {"ok": false, "reason": "not_found"}
    if str(bag.get("state", STATE_FLOATING)) != expected_state:
        _release_lock(bag_id)
        return {"ok": false, "reason": "not_sunk"}
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

    var moved := _add_item(player.player_resource.inventory, item_id, amount)
    if moved <= 0:
        return {"ok": false, "reason": "inventory_full", "contents": contents}

    var remaining := amount - moved
    if remaining <= 0:
        contents.erase(slot_uid)
    else:
        slot["a"] = remaining
        contents[slot_uid] = slot

    _touch_lock(bag_id, peer_id)
    world_server.database.save_player(player.player_resource)

    if contents.is_empty():
        db.query_with_bindings("DELETE FROM death_bags WHERE bag_id=?;", [bag_id])
        _release_lock(bag_id)
        _broadcast(instance, "pirateworld.death_bag.remove", {"bag_id": bag_id})
        return {
            "ok": true,
            "bag_id": bag_id,
            "slot_uid": slot_uid,
            "moved": moved,
            "remaining": 0,
            "emptied": true,
            "contents": {},
        }

    db.query_with_bindings("UPDATE death_bags SET contents_json=? WHERE bag_id=?;", [JSON.stringify(contents), bag_id])
    _broadcast(instance, "pirateworld.death_bag.changed", {"bag_id": bag_id, "contents": contents})
    return {
        "ok": true,
        "bag_id": bag_id,
        "slot_uid": slot_uid,
        "moved": moved,
        "remaining": remaining,
        "emptied": false,
        "contents": contents,
    }


func player_distance(instance, peer_id: int, bag: Dictionary) -> float:
    var player = instance.get_player(peer_id)
    if player == null:
        return 999999.0
    return player.global_position.distance_to(bag.position)


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


func _item_stack_limit(item_id: int) -> int:
    var item: Item = ContentRegistryHub.load_by_id(&"items", item_id) as Item
    if item == null:
        return 1
    return int(item.stack_limit)


func _item_stack_limit(item_id: int) -> int:
    var item: Item = ContentRegistryHub.load_by_id(&"items", item_id) as Item
    if item == null:
        return 1
    return int(item.stack_limit)


func _add_item(inventory: Dictionary, item_id: int, amount: int) -> int:
    if item_id <= 0 or amount <= 0:
        return 0

    var stack_limit := _item_stack_limit(item_id)
    var remaining := amount

    for slot_uid in inventory.keys():
        var slot = inventory[slot_uid]
        if not slot is Dictionary or int(slot.get("id", 0)) != item_id:
            continue
        var current := int(slot.get("a", 0))
        if stack_limit <= 1:
            continue
        var room := amount if stack_limit <= 0 else max(0, stack_limit - current)
        if room <= 0:
            continue
        var moved := min(remaining, room)
        slot["a"] = current + moved
        inventory[slot_uid] = slot
        remaining -= moved
        if remaining <= 0:
            return amount

    while remaining > 0 and inventory.size() < INVENTORY_SLOT_CAPACITY:
        var new_slot_id := "death_bag_" + str(Time.get_ticks_usec()) + "_" + str(inventory.size())
        var moved := remaining if stack_limit <= 1 or stack_limit <= 0 else min(remaining, stack_limit)
        inventory[new_slot_id] = {"id": item_id, "a": moved}
        remaining -= moved

    return amount - remaining

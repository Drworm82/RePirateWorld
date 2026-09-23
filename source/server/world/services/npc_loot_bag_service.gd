extends RefCounted
## Phase 2: temporary NPC loot bags.
## Unlike player Death Bags, these bags are intentionally NOT persisted.
## Their lifetime is bounded by the loaded server instance: server restart or
## instance unload clears them and the map's NPC population is recreated.

const PICKUP_DISTANCE: float = 96.0
const ACCESS_TIMEOUT_MS: int = 60_000

var world_server
var _next_bag_id: int = 1
var _bags_by_instance: Dictionary = {}
var _locks: Dictionary = {}


func _init(server) -> void:
	world_server = server


func spawn_from_npc(instance, npc: HostileNpc, contents: Dictionary) -> Dictionary:
	if instance == null or npc == null or contents.is_empty():
		return {"ok": false, "reason": "empty_loot"}

	var server_instance = _resolve_server_instance(instance)
	if server_instance == null:
		ServerLog.error("[NPC_LOOT_BAG] spawn failed: could not resolve ServerInstance from %s" % str(instance.name))
		return {"ok": false, "reason": "instance_not_found"}

	var instance_name := str(server_instance.instance_resource.instance_name)
	var bag_id := _next_bag_id
	_next_bag_id += 1

	var bag := {
		"bag_id": bag_id,
		"instance_name": instance_name,
		"position": npc.global_position,
		"enemy_type": str(npc.enemy_type),
		"owner_name": npc.display_name,
		"contents": contents.duplicate(true),
	}
	if not _bags_by_instance.has(instance_name):
		_bags_by_instance[instance_name] = {}
	var bags: Dictionary = _bags_by_instance[instance_name]
	bags[bag_id] = bag

	ServerLog.info("[NPC_LOOT_BAG] spawn bag_id=%d enemy=%s instance=%s slots=%d" % [
		bag_id, str(npc.enemy_type), instance_name, contents.size()
	])
	_broadcast(server_instance, &"pirateworld.npc_loot_bag.spawn", _public_bag(bag))
	return {"ok": true, "bag": _public_bag(bag)}


func _resolve_server_instance(node: Node):
	var current: Node = node
	while current != null:
		# ServerInstance is the first ancestor exposing the instance player API.
		# NPCs can be nested under organizational nodes inside Map, so fixed
		# get_parent().get_parent() traversal is not safe for loot spawning.
		if current.has_method("get_player") and current.has_method("despawn_player"):
			return current
		current = current.get_parent()
	return null


func list_for_instance(instance_name: String) -> Array:
	var result: Array = []
	var bags: Dictionary = _bags_by_instance.get(instance_name, {})
	for bag_id in bags:
		result.append(_public_bag(bags[bag_id]))
	return result


func open(peer_id: int, instance, bag_id: int) -> Dictionary:
	var bag := _get_bag(instance, bag_id)
	if bag.is_empty():
		return {"ok": false, "reason": "not_found"}

	var player = instance.get_player(peer_id)
	if player == null or player.player_resource == null:
		return {"ok": false, "reason": "player_not_found"}
	if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
		return {"ok": false, "reason": "too_far"}

	_expire_lock_if_needed(bag_id)
	if _locks.has(bag_id) and int(_locks[bag_id].get("peer_id", -1)) != peer_id:
		return {"ok": false, "reason": "in_use"}
	_locks[bag_id] = {"peer_id": peer_id, "last_action_ms": Time.get_ticks_msec()}

	return {
		"ok": true,
		"bag_id": bag_id,
		"enemy_type": bag.enemy_type,
		"owner_name": bag.owner_name,
		"contents": bag.contents.duplicate(true),
	}


func loot(peer_id: int, instance, bag_id: int, slot_uid: String) -> Dictionary:
	var bag := _get_bag(instance, bag_id)
	if bag.is_empty():
		_release_lock(bag_id)
		return {"ok": false, "reason": "not_found"}
	if not _owns_lock(bag_id, peer_id):
		return {"ok": false, "reason": "not_open"}

	var player = instance.get_player(peer_id)
	if player == null or player.player_resource == null:
		return {"ok": false, "reason": "player_not_found"}
	if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
		_release_lock(bag_id)
		return {"ok": false, "reason": "too_far"}
	if not bag.contents.has(slot_uid):
		return {"ok": false, "reason": "slot_gone", "contents": bag.contents}

	var slot = bag.contents[slot_uid]
	if not slot is Dictionary:
		return {"ok": false, "reason": "invalid_slot", "contents": bag.contents}
	var item_id := int(slot.get("id", 0))
	var amount := int(slot.get("a", 0))
	if item_id <= 0 or amount <= 0:
		return {"ok": false, "reason": "invalid_slot", "contents": bag.contents}

	var moved := _add_item(player.player_resource.inventory, item_id, amount)
	if moved <= 0:
		return {"ok": false, "reason": "inventory_full", "contents": bag.contents}
	DailyQuestService.on_collect(player.player_resource, item_id, moved)

	var remaining := amount - moved
	if remaining <= 0:
		bag.contents.erase(slot_uid)
	else:
		slot["a"] = remaining
		bag.contents[slot_uid] = slot

	world_server.database.save_player(player.player_resource)
	_touch_lock(bag_id, peer_id)

	if bag.contents.is_empty():
		_delete_bag(instance, bag_id)
		return {"ok": true, "bag_id": bag_id, "emptied": true, "contents": {}}

	_broadcast(instance, &"pirateworld.npc_loot_bag.changed", {
		"bag_id": bag_id, "contents": bag.contents.duplicate(true)
	})
	return {
		"ok": true,
		"bag_id": bag_id,
		"moved": moved,
		"emptied": false,
		"contents": bag.contents.duplicate(true),
	}


func loot_all(peer_id: int, instance, bag_id: int) -> Dictionary:
	var bag := _get_bag(instance, bag_id)
	if bag.is_empty():
		_release_lock(bag_id)
		return {"ok": false, "reason": "not_found"}
	if not _owns_lock(bag_id, peer_id):
		return {"ok": false, "reason": "not_open"}

	var player = instance.get_player(peer_id)
	if player == null or player.player_resource == null:
		return {"ok": false, "reason": "player_not_found"}
	if player.global_position.distance_to(bag.position) > PICKUP_DISTANCE:
		_release_lock(bag_id)
		return {"ok": false, "reason": "too_far"}

	var moved_total := 0
	for slot_uid in bag.contents.keys():
		var slot = bag.contents[slot_uid]
		if not slot is Dictionary:
			continue
		var item_id := int(slot.get("id", 0))
		var amount := int(slot.get("a", 0))
		if item_id <= 0 or amount <= 0:
			continue
		var moved := _add_item(player.player_resource.inventory, item_id, amount)
		if moved > 0:
			DailyQuestService.on_collect(player.player_resource, item_id, moved)
		moved_total += moved
		var remaining := amount - moved
		if remaining <= 0:
			bag.contents.erase(slot_uid)
		else:
			slot["a"] = remaining
			bag.contents[slot_uid] = slot

	if moved_total <= 0:
		return {"ok": false, "reason": "inventory_full", "contents": bag.contents}

	world_server.database.save_player(player.player_resource)
	_touch_lock(bag_id, peer_id)

	if bag.contents.is_empty():
		_delete_bag(instance, bag_id)
		return {"ok": true, "bag_id": bag_id, "moved": moved_total, "emptied": true, "contents": {}}

	_broadcast(instance, &"pirateworld.npc_loot_bag.changed", {
		"bag_id": bag_id, "contents": bag.contents.duplicate(true)
	})
	return {
		"ok": true,
		"bag_id": bag_id,
		"moved": moved_total,
		"emptied": false,
		"contents": bag.contents.duplicate(true),
	}


func close(peer_id: int, _instance, bag_id: int) -> Dictionary:
	if not _owns_lock(bag_id, peer_id):
		return {"ok": false, "reason": "not_open"}
	_release_lock(bag_id)
	return {"ok": true, "bag_id": bag_id}


func clear_instance(instance_name: String) -> void:
	var bags: Dictionary = _bags_by_instance.get(instance_name, {})
	for bag_id in bags.keys():
		_release_lock(int(bag_id))
	_bags_by_instance.erase(instance_name)


func _get_bag(instance, bag_id: int) -> Dictionary:
	if instance == null or bag_id <= 0:
		return {}
	var instance_name := str(instance.instance_resource.instance_name)
	var bags: Dictionary = _bags_by_instance.get(instance_name, {})
	var bag = bags.get(bag_id, null)
	return bag if bag is Dictionary else {}


func _delete_bag(instance, bag_id: int) -> void:
	var instance_name := str(instance.instance_resource.instance_name)
	var bags: Dictionary = _bags_by_instance.get(instance_name, {})
	bags.erase(bag_id)
	_release_lock(bag_id)
	_broadcast(instance, &"pirateworld.npc_loot_bag.remove", {"bag_id": bag_id})
	ServerLog.info("[NPC_LOOT_BAG] remove bag_id=%d instance=%s" % [bag_id, instance_name])


func _public_bag(bag: Dictionary) -> Dictionary:
	return {
		"bag_id": int(bag.get("bag_id", 0)),
		"instance_name": str(bag.get("instance_name", "")),
		"position": bag.get("position", Vector2.ZERO),
		"enemy_type": str(bag.get("enemy_type", "")),
		"owner_name": str(bag.get("owner_name", "Enemigo")),
		"contents": bag.get("contents", {}).duplicate(true),
	}


func _broadcast(instance, message_type: StringName, payload: Dictionary) -> void:
	if instance == null or world_server == null:
		return
	var peers: PackedInt64Array = instance.connected_peers
	ServerLog.info("[NPC_LOOT_BAG] broadcast type=%s instance=%s peers=%d bag_id=%d" % [
		str(message_type),
		str(instance.instance_resource.instance_name),
		peers.size(),
		int(payload.get("bag_id", 0)),
	])
	for peer_id in peers:
		world_server.data_push.rpc_id(peer_id, message_type, payload)


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
	if stack_limit == 0 or stack_limit > 1:
		for slot_uid in inventory.keys():
			var slot = inventory[slot_uid]
			if not slot is Dictionary or int(slot.get("id", 0)) != item_id:
				continue
			var current := int(slot.get("a", 0))
			var room: int = remaining if stack_limit == 0 else maxi(0, stack_limit - current)
			if room <= 0:
				continue
			var moved: int = mini(remaining, room)
			slot["a"] = current + moved
			inventory[slot_uid] = slot
			remaining -= moved
			if remaining <= 0:
				return amount
	while remaining > 0:
		var moved: int = remaining if stack_limit == 0 or stack_limit <= 1 else mini(remaining, stack_limit)
		inventory[Inventory.next_uid(inventory)] = {"id": item_id, "a": moved}
		remaining -= moved
	return amount


func _owns_lock(bag_id: int, peer_id: int) -> bool:
	_expire_lock_if_needed(bag_id)
	return _locks.has(bag_id) and int(_locks[bag_id].get("peer_id", -1)) == peer_id


func _touch_lock(bag_id: int, peer_id: int) -> void:
	if _owns_lock(bag_id, peer_id):
		_locks[bag_id]["last_action_ms"] = Time.get_ticks_msec()


func _expire_lock_if_needed(bag_id: int) -> void:
	if not _locks.has(bag_id):
		return
	if Time.get_ticks_msec() - int(_locks[bag_id].get("last_action_ms", 0)) >= ACCESS_TIMEOUT_MS:
		_locks.erase(bag_id)


func _release_lock(bag_id: int) -> void:
	_locks.erase(bag_id)

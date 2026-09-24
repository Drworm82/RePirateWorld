extends RefCounted
## Phase 2 MVP: server-authoritative multiplayer turn-based ground-combat encounters.
##
## One encounter can contain multiple players and multiple Goblin/Bandit NPCs.
## A player entering an engaged NPC joins its encounter. A player already in an
## encounter can pull another valid NPC into that encounter. If two separate
## encounters touch, they are merged.

const BANDIT_TYPE: StringName = &"bandit"
const GOBLIN_PREFIX := "goblin_"
const ENEMY_SPEED := 5
const ITEM_HEAL_ID := 1
const ITEM_HEAL_AMOUNT := 20

var world_server
var _next_encounter_id := 1
var _encounters: Dictionary = {}
var _player_encounter: Dictionary = {}
var _enemy_encounter: Dictionary = {}


func _init(server) -> void:
	world_server = server


func try_start(player: Player, enemy: HostileNpc) -> bool:
	if player == null or enemy == null or not GameMode.is_world_server():
		return false
	if not _is_ground_enemy(enemy) or player.is_dead or enemy.is_dead:
		return false

	var peer_id := int(player.player_resource.current_peer_id)
	if peer_id <= 0:
		return false

	var enemy_id := enemy.get_instance_id()
	var player_eid := int(_player_encounter.get(peer_id, 0))
	var enemy_eid := int(_enemy_encounter.get(enemy_id, 0))

	if player_eid > 0 and enemy_eid > 0:
		if player_eid == enemy_eid:
			return true
		_merge_encounters(player_eid, enemy_eid)
		_push_state(_encounters[player_eid], "encounters_merged")
		return true

	if player_eid > 0 and _encounters.has(player_eid):
		var battle: Dictionary = _encounters[player_eid]
		_add_enemy(battle, enemy)
		_encounters[player_eid] = battle
		_push_state(battle, "enemy_joined")
		return true

	if enemy_eid > 0 and _encounters.has(enemy_eid):
		var battle: Dictionary = _encounters[enemy_eid]
		_add_player(battle, player)
		_encounters[enemy_eid] = battle
		_push_state(battle, "player_joined")
		return true

	var id := _next_encounter_id
	_next_encounter_id += 1
	var battle := {
		"id": id,
		"players": {peer_id: player},
		"enemies": [enemy],
		"turn_order": [],
		"turn_index": 0,
		"player_defending": {peer_id: false},
		"enemy_defending": {enemy_id: false},
		"enemy_target_index": 0,
	}
	_encounters[id] = battle
	_player_encounter[peer_id] = id
	_enemy_encounter[enemy_id] = id
	_freeze_enemy(enemy)
	_build_turn_order(battle, true)
	_encounters[id] = battle

	_push_lock(peer_id, true)
	_push_state(battle, "start")
	ServerLog.info("[GROUND_COMBAT] encounter_start id=%d players=%d enemies=%d" % [
		id, battle["players"].size(), battle["enemies"].size()
	])
	_run_turn(battle)
	return true


func _is_ground_enemy(enemy: HostileNpc) -> bool:
	var t := String(enemy.enemy_type)
	return enemy.enemy_type == BANDIT_TYPE or t.begins_with(GOBLIN_PREFIX)


func is_npc_locked(enemy: HostileNpc) -> bool:
	return is_npc_in_encounter(enemy)


func is_npc_in_encounter(enemy: HostileNpc) -> bool:
	return enemy != null and _enemy_encounter.has(enemy.get_instance_id())


func is_player_locked(peer_id: int) -> bool:
	return _player_encounter.has(peer_id)


func perform_action(peer_id: int, action: String, target_enemy_id: String = "") -> Dictionary:
	var eid := int(_player_encounter.get(peer_id, 0))
	if eid <= 0 or not _encounters.has(eid):
		return {"ok": false, "reason": "not_in_combat"}

	var battle: Dictionary = _encounters[eid]
	if _current_token(battle) != "p:%d" % peer_id:
		return {"ok": false, "reason": "not_your_turn"}

	var player: Player = battle["players"].get(peer_id, null)
	if not is_instance_valid(player) or player.is_dead:
		_remove_player(battle, peer_id, "defeat")
		return {"ok": false, "reason": "combat_already_finished"}

	if action == "flee":
		_remove_player(battle, peer_id, "fled")
		return {"ok": true, "ended": not _encounters.has(eid), "result": "fled"}

	var result: Dictionary
	var target_enemy: HostileNpc = null
	match action:
		"attack":
			target_enemy = _find_enemy(battle, target_enemy_id)
			if target_enemy == null:
				return {"ok": false, "reason": "invalid_target"}
			result = _attack(battle, player, target_enemy, false)
		"ability":
			target_enemy = _find_enemy(battle, target_enemy_id)
			if target_enemy == null:
				return {"ok": false, "reason": "invalid_target"}
			result = _attack(battle, player, target_enemy, true)
		"item":
			result = _item(battle, player)
		"defend":
			battle["player_defending"][peer_id] = true
			result = {"ok": true, "action": "defend"}
		_:
			return {"ok": false, "reason": "invalid_action"}

	_encounters[eid] = battle
	if not result.get("ok", false):
		_push_state(battle, "action_failed")
		return result

	if not _encounters.has(eid):
		return result
	battle = _encounters[eid]
	_cleanup_dead_enemies(battle)
	if not _encounters.has(eid):
		return result
	_advance_turn(battle)
	return result


func flee(peer_id: int) -> Dictionary:
	return perform_action(peer_id, "flee")


func _attack(battle: Dictionary, player: Player, enemy: HostileNpc, heavy: bool) -> Dictionary:
	var attack := player.stats_component.get_stat(Stat.AD)
	var defense := enemy.stats_component.get_stat(Stat.ARMOR)
	var damage := maxf(1.0, attack * (1.5 if heavy else 1.0) - defense * 0.5)
	var enemy_id := enemy.get_instance_id()
	if bool(battle["enemy_defending"].get(enemy_id, false)):
		damage *= 0.5
		damage = maxf(1.0, damage)
		battle["enemy_defending"][enemy_id] = false
	enemy.take_damage(damage, player)
	return {
		"ok": true,
		"action": "ability" if heavy else "attack",
		"damage": int(round(damage)),
		"target_enemy_id": str(enemy_id),
	}


func _item(battle: Dictionary, player: Player) -> Dictionary:
	if not Inventory.has_item(player.player_resource.inventory, ITEM_HEAL_ID):
		return {"ok": false, "reason": "item_missing"}
	var current := player.stats_component.get_stat(Stat.HEALTH)
	var maximum := player.stats_component.get_stat(Stat.HEALTH_MAX)
	if current >= maximum:
		return {"ok": false, "reason": "health_full"}
	Inventory.remove_one_by_id(player.player_resource.inventory, ITEM_HEAL_ID)
	player.stats_component.set_stat(Stat.HEALTH, minf(maximum, current + ITEM_HEAL_AMOUNT))
	world_server.database.save_player(player.player_resource)
	return {"ok": true, "action": "item", "player_hp": int(round(player.stats_component.get_stat(Stat.HEALTH)))}


func _enemy_turn(battle: Dictionary, enemy_id: int) -> void:
	var enemy := instance_from_id(enemy_id) as HostileNpc
	if not is_instance_valid(enemy) or enemy.is_dead:
		_cleanup_dead_enemies(battle)
		if _encounters.has(int(battle["id"])):
			_advance_turn(battle)
		return

	var peer_id := _choose_target(battle)
	if peer_id <= 0:
		_check_end(battle)
		return
	var player: Player = battle["players"].get(peer_id, null)
	if not is_instance_valid(player) or player.is_dead:
		_remove_player(battle, peer_id, "defeat")
		return

	var hp := enemy.stats_component.get_stat(Stat.HEALTH)
	var max_hp := enemy.stats_component.get_stat(Stat.HEALTH_MAX)
	if max_hp > 0.0 and hp / max_hp <= 0.30:
		battle["enemy_defending"][enemy_id] = true
		_encounters[int(battle["id"])] = battle
		_push_state(battle, "enemy_defend")
		_advance_turn(battle)
		return

	var damage := maxf(1.0, enemy.stats_component.get_stat(Stat.AD) - player.stats_component.get_stat(Stat.ARMOR) * 0.5)
	if bool(battle["player_defending"].get(peer_id, false)):
		damage = maxf(1.0, damage * 0.5)
		battle["player_defending"][peer_id] = false
	_encounters[int(battle["id"])] = battle
	player.take_damage(damage, enemy)
	ServerLog.info("[GROUND_COMBAT] enemy_attack encounter=%d enemy=%s enemy_id=%d target_peer=%d damage=%d target_hp=%d turn=%s" % [
		int(battle["id"]),
		enemy.display_name,
		enemy_id,
		peer_id,
		int(round(damage)),
		int(round(player.stats_component.get_stat(Stat.HEALTH))),
		_current_token(battle)
	])
	_push_state(battle, "enemy_attack")
	if not is_instance_valid(player) or player.is_dead:
		_remove_player(battle, peer_id, "defeat")
		return
	_advance_turn(battle)


func _choose_target(battle: Dictionary) -> int:
	var peers: Array = battle["players"].keys()
	peers.sort()
	if peers.is_empty():
		return 0

	var start_index := clampi(int(battle.get("enemy_target_index", 0)), 0, peers.size() - 1)
	for offset in range(peers.size()):
		var index := (start_index + offset) % peers.size()
		var peer_id := int(peers[index])
		var player: Player = battle["players"][peer_id]
		if is_instance_valid(player) and not player.is_dead:
			battle["enemy_target_index"] = (index + 1) % peers.size()
			ServerLog.info("[GROUND_COMBAT] target_selected encounter=%d target_peer=%d target_index=%d next_target_index=%d players=%d" % [
				int(battle["id"]),
				peer_id,
				index,
				int(battle["enemy_target_index"]),
				peers.size()
			])
			return peer_id
	return 0


func _find_enemy(battle: Dictionary, wanted_id: String) -> HostileNpc:
	if wanted_id.is_empty():
		for enemy: HostileNpc in battle["enemies"]:
			if is_instance_valid(enemy) and not enemy.is_dead:
				return enemy
		return null
	var id := int(wanted_id)
	for enemy: HostileNpc in battle["enemies"]:
		if is_instance_valid(enemy) and not enemy.is_dead and enemy.get_instance_id() == id:
			return enemy
	return null


func _freeze_enemy(enemy: HostileNpc) -> void:
	enemy.targeted_player = null
	enemy.velocity = Vector2.ZERO


func _add_player(battle: Dictionary, player: Player) -> void:
	var peer_id := int(player.player_resource.current_peer_id)
	if peer_id <= 0 or battle["players"].has(peer_id):
		return
	battle["players"][peer_id] = player
	battle["player_defending"][peer_id] = false
	_player_encounter[peer_id] = int(battle["id"])
	player.velocity = Vector2.ZERO
	_push_lock(peer_id, true)
	_build_turn_order(battle, false)


func _add_enemy(battle: Dictionary, enemy: HostileNpc) -> void:
	var enemy_id := enemy.get_instance_id()
	if _enemy_encounter.has(enemy_id):
		return
	battle["enemies"].append(enemy)
	battle["enemy_defending"][enemy_id] = false
	_enemy_encounter[enemy_id] = int(battle["id"])
	_freeze_enemy(enemy)
	_build_turn_order(battle, false)


func _merge_encounters(first_id: int, second_id: int) -> void:
	if not _encounters.has(first_id) or not _encounters.has(second_id):
		return
	var first: Dictionary = _encounters[first_id]
	var second: Dictionary = _encounters[second_id]
	for peer_id in second["players"].keys():
		first["players"][peer_id] = second["players"][peer_id]
		first["player_defending"][peer_id] = second["player_defending"].get(peer_id, false)
		_player_encounter[peer_id] = first_id
		_push_lock(int(peer_id), true)
	for enemy: HostileNpc in second["enemies"]:
		if is_instance_valid(enemy):
			first["enemies"].append(enemy)
			first["enemy_defending"][enemy.get_instance_id()] = second["enemy_defending"].get(enemy.get_instance_id(), false)
			_enemy_encounter[enemy.get_instance_id()] = first_id
			_freeze_enemy(enemy)
	_encounters.erase(second_id)
	_encounters[first_id] = first
	_build_turn_order(first, false)


func _build_turn_order(battle: Dictionary, initial: bool) -> void:
	var order: Array = battle["turn_order"]
	if initial or order.is_empty():
		order.clear()
		var entries: Array = []
		for peer_id in battle["players"].keys():
			var player: Player = battle["players"][peer_id]
			if is_instance_valid(player) and not player.is_dead:
				entries.append({
					"token": "p:%d" % int(peer_id),
					"speed": maxi(1, int(player.stats_component.get_stat(Stat.MOVE_SPEED) / 10.0)),
					"team": 0
				})
		for enemy: HostileNpc in battle["enemies"]:
			if is_instance_valid(enemy) and not enemy.is_dead:
				entries.append({"token": "e:%d" % enemy.get_instance_id(), "speed": ENEMY_SPEED, "team": 1})
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["speed"]) == int(b["speed"]):
				return int(a["team"]) < int(b["team"])
			return int(a["speed"]) > int(b["speed"])
		)
		for entry in entries:
			order.append(entry["token"])
		battle["turn_index"] = 0
	else:
		for peer_id in battle["players"].keys():
			var ptoken := "p:%d" % int(peer_id)
			if not order.has(ptoken):
				order.append(ptoken)
		for enemy: HostileNpc in battle["enemies"]:
			var etoken := "e:%d" % enemy.get_instance_id()
			if not order.has(etoken):
				order.append(etoken)
	battle["turn_order"] = order


func _current_token(battle: Dictionary) -> String:
	var order: Array = battle["turn_order"]
	if order.is_empty():
		return ""
	return str(order[clampi(int(battle["turn_index"]), 0, order.size() - 1)])


func _token_alive(battle: Dictionary, token: String) -> bool:
	if token.begins_with("p:"):
		var player: Player = battle["players"].get(int(token.trim_prefix("p:")), null) as Player
		return is_instance_valid(player) and not player.is_dead
	var enemy_id := int(token.trim_prefix("e:"))
	var enemy := instance_from_id(enemy_id) as HostileNpc
	return is_instance_valid(enemy) and not enemy.is_dead and int(_enemy_encounter.get(enemy_id, 0)) == int(battle["id"])


func _advance_turn(battle: Dictionary) -> void:
	var id := int(battle["id"])
	if not _encounters.has(id):
		return
	_cleanup_dead_enemies(battle)
	if not _encounters.has(id) or _check_end(battle):
		return
	var order: Array = battle["turn_order"]
	if order.is_empty():
		_end_encounter(battle, "cancelled")
		return
	var current := int(battle["turn_index"])
	for step in range(1, order.size() + 1):
		var candidate := (current + step) % order.size()
		if _token_alive(battle, str(order[candidate])):
			battle["turn_index"] = candidate
			break
	_encounters[id] = battle
	_run_turn(battle)


func _run_turn(battle: Dictionary) -> void:
	var id := int(battle["id"])
	if not _encounters.has(id) or _check_end(battle):
		return
	var token := _current_token(battle)
	if token.begins_with("e:"):
		_enemy_turn(battle, int(token.trim_prefix("e:")))
	else:
		_push_state(battle, "player_turn")


func _cleanup_dead_enemies(battle: Dictionary) -> void:
	var alive: Array = []
	for enemy: HostileNpc in battle["enemies"]:
		if is_instance_valid(enemy) and not enemy.is_dead:
			alive.append(enemy)
		else:
			if is_instance_valid(enemy):
				_enemy_encounter.erase(enemy.get_instance_id())
	battle["enemies"] = alive
	if alive.is_empty():
		_end_encounter(battle, "victory")


func _remove_player(battle: Dictionary, peer_id: int, result: String) -> void:
	var id := int(battle["id"])
	if not _encounters.has(id):
		return
	var player: Player = battle["players"].get(peer_id, null)
	battle["players"].erase(peer_id)
	battle["player_defending"].erase(peer_id)
	_player_encounter.erase(peer_id)
	_push_lock(peer_id, false)
	if WorldServer.curr != null:
		WorldServer.curr.data_push.rpc_id(peer_id, &"ground_combat.end", {
			"result": result,
			"enemy_name": "Encuentro"
		})
	if is_instance_valid(player):
		for enemy: HostileNpc in battle["enemies"]:
			if is_instance_valid(enemy) and enemy.targeted_player == player:
				enemy.targeted_player = null
				enemy.possible_targets.erase(player)
	if battle["players"].is_empty():
		_end_encounter(battle, result)
		return
	_encounters[id] = battle
	_build_turn_order(battle, false)
	_push_state(battle, "player_left")
	_advance_turn(battle)


func _cleanup_dead_players(battle: Dictionary) -> void:
	var dead_peers: Array = []
	for peer_id in battle["players"].keys():
		var player: Player = battle["players"][peer_id]
		if not is_instance_valid(player) or player.is_dead:
			dead_peers.append(int(peer_id))
	for peer_id in dead_peers:
		battle["players"].erase(peer_id)
		battle["player_defending"].erase(peer_id)
		_player_encounter.erase(peer_id)
		_push_lock(peer_id, false)
		if WorldServer.curr != null:
			WorldServer.curr.data_push.rpc_id(peer_id, &"ground_combat.end", {
				"result": "defeat",
				"enemy_name": "Encuentro"
			})

func _check_end(battle: Dictionary) -> bool:
	var had_dead_player := false
	var dead_peers: Array = []
	for peer_id in battle["players"].keys():
		var player: Player = battle["players"][peer_id]
		if not is_instance_valid(player) or player.is_dead:
			dead_peers.append(int(peer_id))
			had_dead_player = true

	_cleanup_dead_players(battle)
	if battle["players"].is_empty():
		_end_encounter(battle, "defeat" if had_dead_player else "cancelled")
		return true
	if battle["enemies"].is_empty():
		_end_encounter(battle, "victory")
		return true
	return false


func end_for_peer(peer_id: int) -> void:
	var id := int(_player_encounter.get(peer_id, 0))
	if id > 0 and _encounters.has(id):
		_remove_player(_encounters[id], peer_id, "cancelled")


func end_for_enemy(enemy: HostileNpc) -> void:
	if enemy == null:
		return
	var enemy_id := enemy.get_instance_id()
	var id := int(_enemy_encounter.get(enemy_id, 0))
	if id <= 0 or not _encounters.has(id):
		return
	var battle: Dictionary = _encounters[id]
	_enemy_encounter.erase(enemy_id)
	battle["enemy_defending"].erase(enemy_id)
	var remaining: Array = []
	for current: HostileNpc in battle["enemies"]:
		if current != enemy and is_instance_valid(current) and not current.is_dead:
			remaining.append(current)
	battle["enemies"] = remaining
	_encounters[id] = battle
	ServerLog.info("[GROUND_COMBAT] enemy_removed encounter=%d enemy=%s remaining=%d" % [
		id, enemy.display_name, remaining.size()
	])
	if remaining.is_empty():
		_end_encounter(battle, "victory")
		return
	_build_turn_order(battle, false)
	_push_state(battle, "enemy_removed")
	if _current_token(battle) == "e:%d" % enemy_id:
		_advance_turn(battle)


func _end_encounter(battle: Dictionary, result: String) -> void:
	var id := int(battle["id"])
	if not _encounters.has(id):
		return
	_encounters.erase(id)
	for peer_id in battle["players"].keys():
		var peer := int(peer_id)
		_player_encounter.erase(peer)
		_push_lock(peer, false)
		if WorldServer.curr != null:
			WorldServer.curr.data_push.rpc_id(peer, &"ground_combat.end", {
				"result": result,
				"enemy_name": "Encuentro"
			})
	for enemy: HostileNpc in battle["enemies"]:
		if is_instance_valid(enemy):
			_enemy_encounter.erase(enemy.get_instance_id())
	ServerLog.info("[GROUND_COMBAT] encounter_end id=%d result=%s" % [id, result])


func _push_state(battle: Dictionary, reason: String) -> void:
	var id := int(battle["id"])
	for peer_id in battle["players"].keys():
		var peer := int(peer_id)
		var player: Player = battle["players"][peer_id]
		if not is_instance_valid(player):
			continue
		var enemies: Array = []
		for enemy: HostileNpc in battle["enemies"]:
			if is_instance_valid(enemy) and not enemy.is_dead:
				enemies.append({
					"id": str(enemy.get_instance_id()),
					"name": enemy.display_name,
					"hp": int(round(enemy.stats_component.get_stat(Stat.HEALTH))),
					"max_hp": int(round(enemy.stats_component.get_stat(Stat.HEALTH_MAX))),
					"defending": bool(battle["enemy_defending"].get(enemy.get_instance_id(), false))
				})
		var players: Array = []
		for other_peer_id in battle["players"].keys():
			var other: Player = battle["players"][other_peer_id]
			if is_instance_valid(other):
				players.append({
					"peer_id": int(other_peer_id),
					"hp": int(round(other.stats_component.get_stat(Stat.HEALTH))),
					"max_hp": int(round(other.stats_component.get_stat(Stat.HEALTH_MAX))),
					"self": int(other_peer_id) == peer
				})
		var token := _current_token(battle)
		WorldServer.curr.data_push.rpc_id(peer, &"ground_combat.state", {
			"reason": reason,
			"encounter_id": id,
			"turn": token,
			"your_turn": token == "p:%d" % peer,
			"enemies": enemies,
			"players": players
		})


func _push_lock(peer_id: int, locked: bool) -> void:
	if WorldServer.curr != null:
		WorldServer.curr.data_push.rpc_id(peer_id, &"ground_combat.lock", {"locked": locked})

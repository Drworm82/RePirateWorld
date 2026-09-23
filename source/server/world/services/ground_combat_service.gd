extends RefCounted
## Phase 2 MVP: server-authoritative 1v1 turn-based ground combat.
## This is intentionally separate from the existing real-time weapon combat layer.
## It reuses Player, HostileNpc, inventory, stats, loot and Player.die().

const BANDIT_TYPE: StringName = &"bandit"
const GOBLIN_PREFIX: String = "goblin_"
const ENEMY_SPEED: int = 5
const ITEM_HEAL_ID: int = 1
const ITEM_HEAL_AMOUNT: int = 20

var world_server
var _battles: Dictionary[int, Dictionary] = {}


func _init(server) -> void:
	world_server = server


func try_start(player: Player, enemy: HostileNpc) -> bool:
	if player == null or enemy == null:
		return false
	if not GameMode.is_world_server():
		return false
	var enemy_type := String(enemy.enemy_type)
	if enemy.enemy_type != BANDIT_TYPE and not enemy_type.begins_with(GOBLIN_PREFIX):
		return false
	if player.is_dead or enemy.is_dead:
		return false

	var peer_id := int(player.player_resource.current_peer_id)
	if peer_id <= 0 or _battles.has(peer_id) or is_npc_locked(enemy):
		return false

	var player_speed := maxi(1, int(player.stats_component.get_stat(Stat.MOVE_SPEED) / 10.0))
	var player_first := player_speed >= ENEMY_SPEED
	var battle := {
		"peer_id": peer_id,
		"player": player,
		"enemy": enemy,
		"turn": &"player" if player_first else &"enemy",
		"player_defending": false,
		"enemy_defending": false,
		"player_speed": player_speed,
		"enemy_speed": ENEMY_SPEED,
	}
	_battles[peer_id] = battle

	enemy.targeted_player = null
	enemy.velocity = Vector2.ZERO
	_push_lock(peer_id, true)
	ServerLog.info("[GROUND_COMBAT] start peer=%d enemy=%s player_speed=%d enemy_speed=%d first=%s" % [
		peer_id,
		enemy.display_name,
		player_speed,
		ENEMY_SPEED,
		"player" if player_first else "enemy",
	])
	_push_state(battle, "start")

	if not player_first:
		_enemy_turn(battle)
	return true


func is_npc_locked(enemy: HostileNpc) -> bool:
	if enemy == null:
		return false
	for battle: Dictionary in _battles.values():
		if battle.get("enemy", null) == enemy:
			return true
	return false


func is_player_locked(peer_id: int) -> bool:
	return _battles.has(peer_id)


func perform_action(peer_id: int, action: String) -> Dictionary:
	if not _battles.has(peer_id):
		return {"ok": false, "reason": "not_in_combat"}

	var battle: Dictionary = _battles[peer_id]
	if str(battle.get("turn", "")) != "player":
		return {"ok": false, "reason": "not_your_turn"}

	var player: Player = battle.get("player", null)
	var enemy: HostileNpc = battle.get("enemy", null)
	if not is_instance_valid(player) or not is_instance_valid(enemy):
		_end_battle(peer_id, "cancelled")
		return {"ok": false, "reason": "combat_target_lost"}
	if player.is_dead or enemy.is_dead:
		return {"ok": false, "reason": "combat_already_finished"}

	ServerLog.info("[GROUND_COMBAT] action peer=%d action=%s turn=%s" % [peer_id, action, str(battle.get("turn", ""))])
	var result: Dictionary
	match action:
		"attack":
			result = _player_attack(battle, false)
		"ability":
			result = _player_attack(battle, true)
		"item":
			result = _player_item(battle)
		"defend":
			battle["player_defending"] = true
			battle["turn"] = &"enemy"
			result = {"ok": true, "action": "defend"}
		"flee":
			_end_battle(peer_id, "fled")
			return {"ok": true, "ended": true, "result": "fled"}
		_:
			return {"ok": false, "reason": "invalid_action"}

	_battles[peer_id] = battle
	if not bool(result.get("ok", false)):
		_push_state(battle, "action_failed")
		return result

	if enemy.is_dead:
		_end_battle(peer_id, "victory")
		return result

	if player.is_dead:
		_end_battle(peer_id, "defeat")
		return result

	_enemy_turn(battle)
	return result


func flee(peer_id: int) -> Dictionary:
	return perform_action(peer_id, "flee")


func _player_attack(battle: Dictionary, heavy: bool) -> Dictionary:
	var player: Player = battle["player"]
	var enemy: HostileNpc = battle["enemy"]
	var attack := player.stats_component.get_stat(Stat.AD)
	var defense := enemy.stats_component.get_stat(Stat.ARMOR)
	var base_damage := attack * (1.5 if heavy else 1.0)
	var damage := maxf(1.0, base_damage - defense * 0.5)
	if bool(battle.get("enemy_defending", false)):
		damage = maxf(1.0, damage * 0.5)
		battle["enemy_defending"] = false

	enemy.take_damage(damage, player)
	battle["turn"] = &"enemy"
	return {
		"ok": true,
		"action": "ability" if heavy else "attack",
		"damage": int(round(damage)),
		"enemy_hp": int(round(enemy.stats_component.get_stat(Stat.HEALTH))),
	}


func _player_item(battle: Dictionary) -> Dictionary:
	var player: Player = battle["player"]
	if not Inventory.has_item(player.player_resource.inventory, ITEM_HEAL_ID):
		return {"ok": false, "reason": "item_missing"}

	if player.stats_component.get_stat(Stat.HEALTH) >= player.stats_component.get_stat(Stat.HEALTH_MAX):
		return {"ok": false, "reason": "health_full"}

	Inventory.remove_one_by_id(player.player_resource.inventory, ITEM_HEAL_ID)
	var current := player.stats_component.get_stat(Stat.HEALTH)
	var maximum := player.stats_component.get_stat(Stat.HEALTH_MAX)
	player.stats_component.set_stat(Stat.HEALTH, minf(maximum, current + ITEM_HEAL_AMOUNT))
	world_server.database.save_player(player.player_resource)

	battle["turn"] = &"enemy"
	return {
		"ok": true,
		"action": "item",
		"heal": int(minf(ITEM_HEAL_AMOUNT, maximum - current)),
		"player_hp": int(round(player.stats_component.get_stat(Stat.HEALTH))),
	}


func _enemy_turn(battle: Dictionary) -> void:
	var peer_id := int(battle["peer_id"])
	if not _battles.has(peer_id):
		return
	var player: Player = battle["player"]
	var enemy: HostileNpc = battle["enemy"]

	if not is_instance_valid(player) or not is_instance_valid(enemy):
		_end_battle(peer_id, "cancelled")
		return
	if enemy.is_dead:
		_end_battle(peer_id, "victory")
		return
	if player.is_dead:
		_end_battle(peer_id, "defeat")
		return

	# Simple deterministic AI: defend when badly hurt, otherwise attack.
	var enemy_hp := enemy.stats_component.get_stat(Stat.HEALTH)
	var enemy_max := enemy.stats_component.get_stat(Stat.HEALTH_MAX)
	if enemy_max > 0.0 and enemy_hp / enemy_max <= 0.30:
		battle["enemy_defending"] = true
		battle["turn"] = &"player"
		battle["player_defending"] = false
		_battles[peer_id] = battle
		_push_state(battle, "enemy_defend")
		return

	var attack := enemy.stats_component.get_stat(Stat.AD)
	var defense := player.stats_component.get_stat(Stat.ARMOR)
	var damage := maxf(1.0, attack - defense * 0.5)
	if bool(battle.get("player_defending", false)):
		damage = maxf(1.0, damage * 0.5)
		battle["player_defending"] = false

	player.take_damage(damage, enemy)
	battle["turn"] = &"player"
	_battles[peer_id] = battle

	if player.is_dead:
		_end_battle(peer_id, "defeat")
		return

	_push_state(battle, "enemy_attack")


func _push_state(battle: Dictionary, reason: String) -> void:
	var peer_id := int(battle["peer_id"])
	var player: Player = battle["player"]
	var enemy: HostileNpc = battle["enemy"]
	if WorldServer.curr == null:
		return
	WorldServer.curr.data_push.rpc_id(peer_id, &"ground_combat.state", {
		"reason": reason,
		"enemy_name": enemy.display_name,
		"enemy_hp": int(round(enemy.stats_component.get_stat(Stat.HEALTH))),
		"enemy_max_hp": int(round(enemy.stats_component.get_stat(Stat.HEALTH_MAX))),
		"player_hp": int(round(player.stats_component.get_stat(Stat.HEALTH))),
		"player_max_hp": int(round(player.stats_component.get_stat(Stat.HEALTH_MAX))),
		"turn": str(battle.get("turn", "player")),
		"player_defending": bool(battle.get("player_defending", false)),
		"enemy_defending": bool(battle.get("enemy_defending", false)),
	})


func _push_lock(peer_id: int, locked: bool) -> void:
	if WorldServer.curr == null:
		return
	WorldServer.curr.data_push.rpc_id(peer_id, &"ground_combat.lock", {"locked": locked})


func _end_battle(peer_id: int, result: String) -> void:
	if not _battles.has(peer_id):
		return
	var battle: Dictionary = _battles[peer_id]
	_battles.erase(peer_id)
	_push_lock(peer_id, false)

	var enemy: HostileNpc = battle.get("enemy", null)
	var player: Player = battle.get("player", null)

	# Flee returns ownership to the normal world AI. The NPC remains alive
	# and resumes pursuit; a later contact creates another turn-based battle.
	# HostileNpc blocks its legacy real-time damage path for Goblins/Bandits.
	if result == "fled" and is_instance_valid(enemy) and is_instance_valid(player) and not enemy.is_dead and not player.is_dead:
		enemy.targeted_player = player
		enemy.enemy_state = HostileNpc.EnemyState.CHASE

	var enemy_hp := 0
	if is_instance_valid(enemy):
		enemy_hp = int(round(enemy.stats_component.get_stat(Stat.HEALTH)))
	if WorldServer.curr != null:
		WorldServer.curr.data_push.rpc_id(peer_id, &"ground_combat.end", {
			"result": result,
			"enemy_name": enemy.display_name if is_instance_valid(enemy) else "Bandit",
			"enemy_hp": enemy_hp,
		})
	ServerLog.info("[GROUND_COMBAT] end peer=%d result=%s" % [peer_id, result])


func end_for_peer(peer_id: int) -> void:
	if _battles.has(peer_id):
		_end_battle(peer_id, "cancelled")

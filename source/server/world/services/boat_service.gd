class_name BoatService
extends RefCounted

## Phase 3 MVP: Tier 0 boat ownership, server-authoritative navigation and
## controlled LAND -> SEA -> LAND transitions. The client sends only intent;
## final boat position is simulated and persisted here.

const SEA_INSTANCE_NAME: String = "sea_navigation"
const OVERWORLD_INSTANCE_NAME: String = "overworld"
const WOODLAND_INSTANCE_NAME: String = "woodland"
const BOAT_SPEED: float = 180.0
const TURN_SPEED: float = 1.35
const SEA_LIMIT_X: float = 1000.0
const SEA_LIMIT_Y: float = 520.0
const PORT_RADIUS: float = 140.0
const SEA_SPAWN: Vector2 = Vector2(0, 0)
const OVERWORLD_PORT: Vector2 = Vector2(2700, 1050)
const WOODLAND_PORT: Vector2 = Vector2(520, 520)

var world_server: WorldServer
var _boats: Dictionary[int, Dictionary] = {}
var _commands: Dictionary[int, Dictionary] = {}
var _tick_accum: float = 0.0

func _init(server: WorldServer) -> void:
	world_server = server

func _process(delta: float) -> void:
	_tick_accum += delta
	if _tick_accum < 0.05:
		return
	var step: float = _tick_accum
	_tick_accum = 0.0
	for owner_id: int in _boats.keys():
		var boat: Dictionary = _boats[owner_id]
		if str(boat.get("state", "")) != "sailing":
			continue
		_simulate_boat(owner_id, boat, step)

func _get_or_load(owner_player_id: int) -> Dictionary:
	if _boats.has(owner_player_id):
		return _boats[owner_player_id]
	var boat: Dictionary = world_server.database.store.get_boat(owner_player_id)
	if boat.is_empty():
		var player: PlayerResource = world_server.connected_players.get(
			world_server.player_id_to_peer_id.get(owner_player_id, 0), null)
		var instance_name: String = OVERWORLD_INSTANCE_NAME
		var position: Vector2 = OVERWORLD_PORT
		if player != null and not String(player.current_instance).is_empty():
			instance_name = String(player.current_instance)
			position = _port_for_instance(instance_name)
		boat = world_server.database.store.create_boat(owner_player_id, instance_name, position.x, position.y)
	if not boat.is_empty():
		_boats[owner_player_id] = boat
	return boat

func get_for_peer(peer_id: int) -> Dictionary:
	var player: PlayerResource = world_server.connected_players.get(peer_id, null)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	var boat := _get_or_load(player.player_id)
	if boat.is_empty():
		return {"ok": false, "reason": "boat_create_failed"}
	_push_to_peer(peer_id, boat)
	return {"ok": true, "boat": _public_state(boat)}

func board(peer_id: int) -> Dictionary:
	var current: ServerInstance = world_server.instance_manager.find_instance_for_peer(peer_id)
	if current == null:
		return {"ok": false, "reason": "instance_not_found"}
	if current.instance_resource == null:
		return {"ok": false, "reason": "instance_not_found"}
	var player: Player = current.get_player(peer_id)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	if current.instance_resource.instance_name != OVERWORLD_INSTANCE_NAME and current.instance_resource.instance_name != WOODLAND_INSTANCE_NAME:
		return {"ok": false, "reason": "not_a_port"}
	var port := _port_for_instance(String(current.instance_resource.instance_name))
	if player.global_position.distance_to(port) > PORT_RADIUS:
		return {"ok": false, "reason": "too_far_from_port"}
	var boat := _get_or_load(player.player_resource.player_id)
	if str(boat.get("state", "docked")) != "docked":
		return {"ok": false, "reason": "boat_not_docked"}
	boat["x"] = port.x
	boat["y"] = port.y
	boat["instance_name"] = String(current.instance_resource.instance_name)
	boat["state"] = "boarded"
	boat["destination_instance"] = ""
	world_server.database.store.save_boat(boat)
	_boats[player.player_resource.player_id] = boat
	_push_state(peer_id, boat, player.global_position)
	return {"ok": true, "boat": _public_state(boat)}

func move(peer_id: int, command: String) -> Dictionary:
	var player: PlayerResource = world_server.connected_players.get(peer_id, null)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	var boat := _get_or_load(player.player_id)
	if boat.is_empty():
		return {"ok": false, "reason": "boat_not_found"}
	var current: ServerInstance = world_server.instance_manager.find_instance_for_peer(peer_id)
	if current == null:
		return {"ok": false, "reason": "instance_not_found"}
	var state := str(boat.get("state", "docked"))
	if state == "boarded" and command == "forward":
		if current.instance_resource.instance_name != OVERWORLD_INSTANCE_NAME and current.instance_resource.instance_name != WOODLAND_INSTANCE_NAME:
			return {"ok": false, "reason": "invalid_departure"}
		boat["destination_instance"] = _other_land(String(current.instance_resource.instance_name))
		boat["instance_name"] = SEA_INSTANCE_NAME
		boat["x"] = SEA_SPAWN.x
		boat["y"] = SEA_SPAWN.y
		boat["heading"] = 0.0 if boat["destination_instance"] == WOODLAND_INSTANCE_NAME else PI
		boat["state"] = "sailing"
		world_server.database.store.save_boat(boat)
		_boats[player.player_resource.player_id] = boat
		_transition_player_to_sea(peer_id, player, current, boat)
		return {"ok": true, "boat": _public_state(boat)}
	if state != "sailing":
		return {"ok": false, "reason": "boat_not_sailing"}
	if command not in ["forward", "reverse", "left", "right", "stop"]:
		return {"ok": false, "reason": "invalid_command"}
	_commands[player.player_id] = {"command": command, "at_ms": Time.get_ticks_msec()}
	return {"ok": true, "command": command}

func disembark(peer_id: int) -> Dictionary:
	var player: PlayerResource = world_server.connected_players.get(peer_id, null)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	var boat := _get_or_load(player.player_id)
	if str(boat.get("state", "")) != "arrived":
		return {"ok": false, "reason": "not_arrived"}
	var current := world_server.instance_manager.find_instance_for_peer(peer_id)
	if current == null or current.instance_resource == null or current.instance_resource.instance_name != SEA_INSTANCE_NAME:
		return {"ok": false, "reason": "not_at_sea"}
	var destination := str(boat.get("destination_instance", ""))
	if destination != WOODLAND_INSTANCE_NAME and destination != OVERWORLD_INSTANCE_NAME:
		return {"ok": false, "reason": "invalid_destination"}
	boat["instance_name"] = destination
	boat["x"] = _port_for_instance(destination).x
	boat["y"] = _port_for_instance(destination).y
	boat["state"] = "docked"
	boat["destination_instance"] = ""
	world_server.database.store.save_boat(boat)
	_boats[player.player_id] = boat
	var target_resource: InstanceResource = world_server.instance_manager.instance_collection.get(destination, null)
	if target_resource == null:
		return {"ok": false, "reason": "destination_missing"}
	var target := target_resource.get_instance()
	if target == null:
		world_server.instance_manager.queue_charge_instance(
			target_resource,
			world_server.instance_manager.player_switch_instance.bind(0, current.get_player(peer_id), current)
		)
	else:
		world_server.instance_manager.player_switch_instance(target, 0, current.get_player(peer_id), current)
	return {"ok": true, "boat": _public_state(boat)}

func on_player_spawned(peer_id: int, player: Player, instance: ServerInstance) -> void:
	if player == null or player.player_resource == null:
		return
	var boat := _get_or_load(player.player_resource.player_id)
	if boat.is_empty():
		return
	if str(boat.get("instance_name", "")) != str(instance.instance_resource.instance_name):
		return
	if str(boat.get("state", "")) == "sailing" or str(boat.get("state", "")) == "arrived":
		var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
		player.mark_just_teleported()
		player.state_synchronizer.set_by_path(^":position", p)
		_push_state(peer_id, boat, p)

func _simulate_boat(owner_id: int, boat: Dictionary, delta: float) -> void:
	var command := str(_commands.get(owner_id, {"command": "stop"}).get("command", "stop"))
	var heading := float(boat.get("heading", 0.0))
	if command == "left":
		heading -= TURN_SPEED * delta
	elif command == "right":
		heading += TURN_SPEED * delta
	elif command == "forward":
		var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
		p += Vector2.RIGHT.rotated(heading) * BOAT_SPEED * delta
		p.x = clampf(p.x, -SEA_LIMIT_X, SEA_LIMIT_X)
		p.y = clampf(p.y, -SEA_LIMIT_Y, SEA_LIMIT_Y)
		boat["x"] = p.x
		boat["y"] = p.y
	boat["heading"] = heading
		if _has_reached_destination(boat, p):
			boat["state"] = "arrived"
			_commands.erase(owner_id)
	boat["heading"] = heading
	world_server.database.store.save_boat(boat)
	var peer_id: int = world_server.player_id_to_peer_id.get(owner_id, 0)
	if peer_id <= 0:
		return
	var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
	var current := world_server.instance_manager.find_instance_for_peer(peer_id)
	if current == null:
		return
	var player := current.get_player(peer_id)
	if player != null:
		player.mark_just_teleported(250)
		player.state_synchronizer.set_by_path(^":position", p)
		world_server.data_push.rpc_id(peer_id, &"player.teleport", {"position": p})
	_push_state(peer_id, boat, p)

func _has_reached_destination(boat: Dictionary, p: Vector2) -> bool:
	if str(boat.get("destination_instance", "")) == WOODLAND_INSTANCE_NAME:
		return p.x >= SEA_LIMIT_X - 40.0
	return p.x <= -SEA_LIMIT_X + 40.0

func _transition_player_to_sea(peer_id: int, player_resource: PlayerResource, current: ServerInstance, boat: Dictionary) -> void:
	var player := current.get_player(peer_id)
	if player == null:
		return
	var sea_res: InstanceResource = world_server.instance_manager.instance_collection.get(SEA_INSTANCE_NAME, null)
	if sea_res == null:
		return
	var sea := sea_res.get_instance()
	if sea == null:
		world_server.instance_manager.queue_charge_instance(
			sea_res,
			world_server.instance_manager.player_switch_instance.bind(0, player, current)
		)
	else:
		world_server.instance_manager.player_switch_instance(sea, 0, player, current)

func _port_for_instance(instance_name: String) -> Vector2:
	return WOODLAND_PORT if instance_name == WOODLAND_INSTANCE_NAME else OVERWORLD_PORT

func _other_land(instance_name: String) -> String:
	return WOODLAND_INSTANCE_NAME if instance_name == OVERWORLD_INSTANCE_NAME else OVERWORLD_INSTANCE_NAME

func _public_state(boat: Dictionary) -> Dictionary:
	return {
		"boat_id": int(boat.get("boat_id", 0)),
		"tier": int(boat.get("tier", 0)),
		"state": str(boat.get("state", "docked")),
		"instance_name": str(boat.get("instance_name", "")),
		"x": float(boat.get("x", 0.0)),
		"y": float(boat.get("y", 0.0)),
		"heading": float(boat.get("heading", 0.0)),
		"destination_instance": str(boat.get("destination_instance", "")),
	}

func _push_to_peer(peer_id: int, boat: Dictionary) -> void:
	var player := world_server.instance_manager.find_instance_for_peer(peer_id)
	var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
	if player != null:
		var pl := player.get_player(peer_id)
		if pl != null:
			p = pl.global_position
	_push_state(peer_id, boat, p)

func _push_state(peer_id: int, boat: Dictionary, player_position: Vector2) -> void:
	world_server.data_push.rpc_id(peer_id, &"boat.state", {
		"boat": _public_state(boat),
		"player_position": player_position,
	})

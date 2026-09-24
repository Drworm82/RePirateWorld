class_name BoatService
extends RefCounted

## Phase 3A: strategic sea navigation.
## The player never pilots the boat directly. The server owns the route, ETA and
## persisted timestamps; the client only requests navigation intents.

const SEA_INSTANCE_NAME: String = "sea_navigation"
const OVERWORLD_INSTANCE_NAME: String = "overworld"
const WOODLAND_INSTANCE_NAME: String = "woodland"

const SEA_LIMIT_X: float = 1000.0
const SEA_LIMIT_Y: float = 520.0
const SEA_SPAWN: Vector2 = Vector2(0, 0)
const OVERWORLD_TARGET: Vector2 = Vector2(-960, 0)
const WOODLAND_TARGET: Vector2 = Vector2(960, 0)

# Tier 0 MVP speed. Later tiers can derive this from sails, hull and cargo.
const AUTONAV_SPEED: float = 60.0
const TICK_INTERVAL: float = 0.25

var world_server: WorldServer
var _boats: Dictionary[int, Dictionary] = {}
var _tick_accum: float = 0.0

func _init(server: WorldServer) -> void:
	world_server = server

func tick(delta: float) -> void:
	_tick_accum += delta
	if _tick_accum < TICK_INTERVAL:
		return
	_tick_accum = 0.0
	for owner_id: int in _boats.keys():
		var boat: Dictionary = _boats[owner_id]
		if str(boat.get("state", "")) != "navigating":
			continue
		_update_autonav(owner_id, boat)

func _get_or_load(owner_player_id: int) -> Dictionary:
	if _boats.has(owner_player_id):
		var cached: Dictionary = _boats[owner_player_id]
		_reconcile_autonav(cached)
		return cached

	var boat: Dictionary = world_server.database.store.get_boat(owner_player_id)
	if boat.is_empty():
		var player: PlayerResource = world_server.connected_players.get(
			world_server.player_id_to_peer_id.get(owner_player_id, 0), null)
		var instance_name: String = OVERWORLD_INSTANCE_NAME
		var position: Vector2 = Vector2.ZERO
		if player != null and not String(player.current_instance).is_empty():
			instance_name = String(player.current_instance)
		boat = world_server.database.store.create_boat(owner_player_id, instance_name, position.x, position.y)
	else:
		_reconcile_autonav(boat)

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
	return {"ok": false, "reason": "manual_boarding_removed_use_sea_navigation"}

func move(peer_id: int, _command: String) -> Dictionary:
	# Intentionally reject the old WASD/joystick control path.
	return {"ok": false, "reason": "manual_navigation_disabled"}

func start_autonav(peer_id: int, destination: String, target_x: float = 0.0, target_y: float = 0.0) -> Dictionary:
	var player: PlayerResource = world_server.connected_players.get(peer_id, null)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	var current := world_server.instance_manager.find_instance_for_peer(peer_id)
	if current == null or current.instance_resource == null:
		return {"ok": false, "reason": "instance_not_found"}
	if str(current.instance_resource.instance_name) != SEA_INSTANCE_NAME:
		return {"ok": false, "reason": "not_at_sea"}

	var boat := _get_or_load(player.player_id)
	if boat.is_empty():
		return {"ok": false, "reason": "boat_not_found"}

	var state := str(boat.get("state", "ready"))
	if state != "ready" and state != "paused_at_sea":
		return {"ok": false, "reason": "boat_not_ready"}

	var target := _resolve_destination(destination, target_x, target_y)
	if target == null:
		return {"ok": false, "reason": "invalid_destination"}

	var p := Vector2(float(boat.get("x", SEA_SPAWN.x)), float(boat.get("y", SEA_SPAWN.y)))
	var distance := p.distance_to(target)
	if distance < 1.0:
		boat["x"] = target.x
		boat["y"] = target.y
		boat["state"] = "arrived"
		boat["destination_instance"] = destination if destination == WOODLAND_INSTANCE_NAME or destination == OVERWORLD_INSTANCE_NAME else ""
		boat["target_x"] = target.x
		boat["target_y"] = target.y
		boat["departure_ms"] = 0
		boat["eta_ms"] = 0
		world_server.database.store.save_boat(boat)
		_push_state_for_owner(peer_id, boat)
		return {"ok": true, "boat": _public_state(boat)}

	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	var eta_ms := now_ms + int(ceil(distance / AUTONAV_SPEED * 1000.0))
	boat["state"] = "navigating"
	boat["destination_instance"] = destination if destination == WOODLAND_INSTANCE_NAME or destination == OVERWORLD_INSTANCE_NAME else ""
	boat["target_x"] = target.x
	boat["target_y"] = target.y
	boat["departure_ms"] = now_ms
	boat["eta_ms"] = eta_ms
	boat["route_start_x"] = p.x
	boat["route_start_y"] = p.y
	boat["heading"] = (target - p).angle()
	world_server.database.store.save_boat(boat)
	_boats[player.player_id] = boat
	_push_state_for_owner(peer_id, boat)
	return {"ok": true, "boat": _public_state(boat)}

func pause_autonav(peer_id: int) -> Dictionary:
	var player: PlayerResource = world_server.connected_players.get(peer_id, null)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	var boat := _get_or_load(player.player_id)
	if str(boat.get("state", "")) != "navigating":
		return {"ok": false, "reason": "not_navigating"}
	_update_autonav(player.player_id, boat)
	if str(boat.get("state", "")) == "arrived":
		return {"ok": true, "boat": _public_state(boat)}
	boat["state"] = "paused_at_sea"
	boat["departure_ms"] = 0
	boat["eta_ms"] = 0
	boat["route_start_x"] = 0.0
	boat["route_start_y"] = 0.0
	world_server.database.store.save_boat(boat)
	_push_state_for_owner(peer_id, boat)
	return {"ok": true, "boat": _public_state(boat)}

func resume_autonav(peer_id: int) -> Dictionary:
	var player: PlayerResource = world_server.connected_players.get(peer_id, null)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}
	var boat := _get_or_load(player.player_id)
	if str(boat.get("state", "")) != "paused_at_sea":
		return {"ok": false, "reason": "not_paused"}
	return start_autonav(peer_id, str(boat.get("destination_instance", "")),
		float(boat.get("target_x", 0.0)), float(boat.get("target_y", 0.0)))

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
	boat["target_x"] = 0.0
	boat["target_y"] = 0.0
	boat["departure_ms"] = 0
	boat["eta_ms"] = 0
	boat["route_start_x"] = 0.0
	boat["route_start_y"] = 0.0
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

	var current_instance_name := str(instance.instance_resource.instance_name)
	var boat_instance_name := str(boat.get("instance_name", ""))

	# Direct testing portal enters sea without requiring a physical dock.
	if current_instance_name == SEA_INSTANCE_NAME and boat_instance_name != SEA_INSTANCE_NAME:
		boat["instance_name"] = SEA_INSTANCE_NAME
		boat["x"] = SEA_SPAWN.x
		boat["y"] = SEA_SPAWN.y
		boat["state"] = "ready"
		boat["destination_instance"] = ""
		boat["target_x"] = 0.0
		boat["target_y"] = 0.0
		boat["departure_ms"] = 0
		boat["eta_ms"] = 0
		world_server.database.store.save_boat(boat)
		_boats[player.player_resource.player_id] = boat

	# Migrate boats created by the previous manual-navigation prototype.
	# A legacy sea "sailing"/"boarded" state without an Autonav timestamp is now ready.
	if current_instance_name == SEA_INSTANCE_NAME and (
			str(boat.get("state", "")) == "sailing" or str(boat.get("state", "")) == "boarded"):
		if int(boat.get("eta_ms", 0)) <= 0:
			boat["state"] = "ready"
			boat["destination_instance"] = ""
			boat["departure_ms"] = 0
			boat["eta_ms"] = 0
			boat["target_x"] = 0.0
			boat["target_y"] = 0.0
			boat["route_start_x"] = 0.0
			boat["route_start_y"] = 0.0
			world_server.database.store.save_boat(boat)
			_boats[player.player_resource.player_id] = boat

	if str(boat.get("instance_name", "")) != current_instance_name:
		return

	_reconcile_autonav(boat)
	var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
	player.mark_just_teleported()
	player.state_synchronizer.set_by_path(^":position", p)
	_push_state(peer_id, boat, p)

func _update_autonav(owner_id: int, boat: Dictionary) -> void:
	if str(boat.get("state", "")) != "navigating":
		return
	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	var departure_ms := int(boat.get("departure_ms", 0))
	var eta_ms := int(boat.get("eta_ms", 0))
	if departure_ms <= 0 or eta_ms <= departure_ms:
		return

	var start := Vector2(float(boat.get("x", SEA_SPAWN.x)), float(boat.get("y", SEA_SPAWN.y)))
	# The persisted x/y is the last authoritative point. To avoid drift across
	# repeated ticks, interpolate from the stored route origin saved in memory.
	var target := Vector2(float(boat.get("target_x", 0.0)), float(boat.get("target_y", 0.0)))
	var total_ms := float(eta_ms - departure_ms)
	var progress := clampf(float(now_ms - departure_ms) / total_ms, 0.0, 1.0)
	var route_start := Vector2(float(boat.get("route_start_x", start.x)), float(boat.get("route_start_y", start.y)))
	boat["x"] = lerpf(route_start.x, target.x, progress)
	boat["y"] = lerpf(route_start.y, target.y, progress)

	if now_ms >= eta_ms:
		boat["x"] = target.x
		boat["y"] = target.y
		boat["state"] = "arrived"
		boat["departure_ms"] = 0
		boat["eta_ms"] = 0
		boat["route_start_x"] = 0.0
		boat["route_start_y"] = 0.0
	world_server.database.store.save_boat(boat)

	var peer_id: int = world_server.player_id_to_peer_id.get(owner_id, 0)
	if peer_id <= 0:
		return
	_push_state_for_owner(peer_id, boat)

func _reconcile_autonav(boat: Dictionary) -> void:
	if str(boat.get("state", "")) != "navigating":
		return
	_update_autonav(int(boat.get("owner_player_id", 0)), boat)

func _resolve_destination(destination: String, target_x: float, target_y: float) -> Variant:
	match destination:
		WOODLAND_INSTANCE_NAME:
			return WOODLAND_TARGET
		OVERWORLD_INSTANCE_NAME:
			return OVERWORLD_TARGET
		"coordinates":
			if absf(target_x) > SEA_LIMIT_X or absf(target_y) > SEA_LIMIT_Y:
				return null
			return Vector2(target_x, target_y)
		_:
			return null

func _port_for_instance(instance_name: String) -> Vector2:
	return WOODLAND_TARGET if instance_name == WOODLAND_INSTANCE_NAME else OVERWORLD_TARGET

func _public_state(boat: Dictionary) -> Dictionary:
	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	var eta_seconds := 0.0
	if str(boat.get("state", "")) == "navigating":
		eta_seconds = maxf(0.0, float(int(boat.get("eta_ms", 0)) - now_ms) / 1000.0)
	return {
		"boat_id": int(boat.get("boat_id", 0)),
		"owner_player_id": int(boat.get("owner_player_id", 0)),
		"tier": int(boat.get("tier", 0)),
		"state": str(boat.get("state", "ready")),
		"instance_name": str(boat.get("instance_name", "")),
		"x": float(boat.get("x", 0.0)),
		"y": float(boat.get("y", 0.0)),
		"heading": float(boat.get("heading", 0.0)),
		"destination_instance": str(boat.get("destination_instance", "")),
		"target_x": float(boat.get("target_x", 0.0)),
		"target_y": float(boat.get("target_y", 0.0)),
		"eta_seconds": eta_seconds,
		"route_start_x": float(boat.get("route_start_x", 0.0)),
		"route_start_y": float(boat.get("route_start_y", 0.0)),
	}

func _push_to_peer(peer_id: int, boat: Dictionary) -> void:
	var player_instance := world_server.instance_manager.find_instance_for_peer(peer_id)
	var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
	if player_instance != null:
		var pl := player_instance.get_player(peer_id)
		if pl != null:
			p = pl.global_position
	_push_state(peer_id, boat, p)

func _push_state_for_owner(peer_id: int, boat: Dictionary) -> void:
	var current := world_server.instance_manager.find_instance_for_peer(peer_id)
	var p := Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0)))
	if current != null:
		var player := current.get_player(peer_id)
		if player != null:
			p = player.global_position
	_push_state(peer_id, boat, p)

func _push_state(peer_id: int, boat: Dictionary, player_position: Vector2) -> void:
	var current := world_server.instance_manager.find_instance_for_peer(peer_id)
	if current == null:
		world_server.data_push.rpc_id(peer_id, &"boat.state", {
			"boat": _public_state(boat),
			"player_position": player_position,
		})
		return
	for target_peer: int in current.connected_peers:
		world_server.data_push.rpc_id(target_peer, &"boat.state", {
			"boat": _public_state(boat),
			"player_position": player_position if target_peer == peer_id else Vector2(float(boat.get("x", 0.0)), float(boat.get("y", 0.0))),
		})

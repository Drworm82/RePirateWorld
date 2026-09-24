extends DataRequestHandler

func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	if WorldServer.curr == null or WorldServer.curr.instance_manager.ground_combat_service == null:
		return {"ok": false, "reason": "service_unavailable"}
	var action := str(args.get("action", ""))
	var target_enemy_id := str(args.get("target_enemy_id", ""))
	return WorldServer.curr.instance_manager.ground_combat_service.perform_action(peer_id, action, target_enemy_id)

extends DataRequestHandler

func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	if WorldServer.curr == null or WorldServer.curr.instance_manager.ground_combat_service == null:
		return {"ok": false, "reason": "service_unavailable"}
	return WorldServer.curr.instance_manager.ground_combat_service.flee(peer_id)

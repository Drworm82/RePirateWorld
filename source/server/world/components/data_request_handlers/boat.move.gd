extends DataRequestHandler

func data_request_handler(peer_id: int, _instance: ServerInstance, args: Dictionary) -> Dictionary:
	if WorldServer.curr == null or WorldServer.curr.instance_manager.boat_service == null:
		return {"ok": false, "reason": "service_unavailable"}
	return WorldServer.curr.instance_manager.boat_service.move(peer_id, str(args.get("command", "")))

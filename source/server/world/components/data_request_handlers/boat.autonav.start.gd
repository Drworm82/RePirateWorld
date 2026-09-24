extends DataRequestHandler

func data_request_handler(peer_id: int, _instance: ServerInstance, args: Dictionary) -> Dictionary:
	if WorldServer.curr == null or WorldServer.curr.instance_manager.boat_service == null:
		return {"ok": false, "reason": "service_unavailable"}
	return WorldServer.curr.instance_manager.boat_service.start_autonav(
		peer_id,
		str(args.get("destination", "")),
		float(args.get("target_x", 0.0)),
		float(args.get("target_y", 0.0))
)

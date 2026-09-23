extends DataRequestHandler

func data_request_handler(peer_id: int, instance: ServerInstance, args: Dictionary) -> Dictionary:
	var service = WorldServer.curr.instance_manager.npc_loot_bag_service if WorldServer.curr != null else null
	if service == null:
		return {"ok": false, "reason": "service_unavailable"}
	return service.close(peer_id, instance, int(args.get("bag_id", 0)))

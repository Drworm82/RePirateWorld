extends DataRequestHandler

func data_request_handler(peer_id: int, instance: ServerInstance, args: Dictionary) -> Dictionary:
	if instance == null or WorldServer.curr == null:
		return {"ok": false, "bags": []}
	var service = WorldServer.curr.instance_manager.npc_loot_bag_service
	if service == null:
		return {"ok": false, "bags": []}
	return {"ok": true, "bags": service.list_for_instance(str(instance.name))}

extends DataRequestHandler

func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	if instance == null or WorldServer.curr == null or WorldServer.curr.instance_manager.death_bag_service == null:
		return {"ok": false, "bags": []}
	return {
		"ok": true,
		"bags": WorldServer.curr.instance_manager.death_bag_service.list_for_instance(str(instance.instance_resource.instance_name)),
	}

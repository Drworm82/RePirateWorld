extends DataRequestHandler

func data_request_handler(
\tpeer_id: int,
\tinstance: ServerInstance,
\targs: Dictionary
) -> Dictionary:
\tvar bag_id: int = int(args.get("bag_id", 0))
\tif WorldServer.curr == null or WorldServer.curr.instance_manager.death_bag_service == null:
\t\treturn {"ok": false, "reason": "service_unavailable"}
\treturn WorldServer.curr.instance_manager.death_bag_service.pickup(peer_id, instance, bag_id)

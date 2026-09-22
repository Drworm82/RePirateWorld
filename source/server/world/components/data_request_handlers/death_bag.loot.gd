extends DataRequestHandler

func data_request_handler(
    peer_id: int,
    instance: ServerInstance,
    args: Dictionary
) -> Dictionary:
    var bag_id: int = int(args.get("bag_id", 0))
    var slot_uid: String = str(args.get("slot_uid", ""))
    if WorldServer.curr == null or WorldServer.curr.instance_manager.death_bag_service == null:
        return {"ok": false, "reason": "service_unavailable"}
    return WorldServer.curr.instance_manager.death_bag_service.loot(peer_id, instance, bag_id, slot_uid)

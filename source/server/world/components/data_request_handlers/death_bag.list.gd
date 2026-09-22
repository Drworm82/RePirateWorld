extends DataRequestHandler

func data_request_handler(
\tpeer_id: int,
\tinstance: ServerInstance,
\targs: Dictionary
) -> Dictionary:
\tif instance == null or WorldServer.curr == null or WorldServer.curr.death_bag_service == null:
\t\treturn {"ok": false, "bags": []}
\treturn {
\t\t"ok": true,
\t\t"bags": WorldServer.curr.death_bag_service.list_for_instance(str(instance.instance_resource.instance_name)),
\t}

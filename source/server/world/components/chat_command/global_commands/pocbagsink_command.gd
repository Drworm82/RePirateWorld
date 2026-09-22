extends ChatCommand
## PirateWorld PoC-03 test command.
## With no argument, forces the latest Death Bag in the current instance into sunk state.
## With a bag_id, forces that specific bag to sink.

func _init() -> void:
    command_name = "pocbagsink"
    command_priority = 0
    command_usage = "/pocbagsink [bag_id]"

func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
    if args.size() > 2:
        return "Usage: " + command_usage

    if WorldServer.curr == null or WorldServer.curr.instance_manager.death_bag_service == null:
        return "Death Bag service is unavailable."

    var service = WorldServer.curr.instance_manager.death_bag_service
    var result: Dictionary

    if args.size() == 1:
        if server_instance == null or server_instance.instance_resource == null:
            return "Current instance is unavailable."
        result = service.force_sink_latest(str(server_instance.instance_resource.instance_name))
    else:
        var bag_id: int = int(args[1])
        if bag_id <= 0:
            return "Invalid bag id."
        result = service.force_sink(bag_id)

    if not bool(result.get("ok", false)):
        return "Death Bag sink failed: %s" % str(result.get("reason", "unknown"))

    return "Death Bag %d is now sunk." % int(result.get("bag_id", 0))

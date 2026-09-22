extends ChatCommand
## PirateWorld PoC-03 test command.
## Forces an existing Death Bag into the sunk state.

func _init() -> void:
    command_name = "pocbagsink"
    command_priority = 0
    command_usage = "/pocbagsink <bag_id>"

func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
    if args.size() != 2:
        return "Usage: " + command_usage

    var bag_id: int = int(args[1])
    if bag_id <= 0:
        return "Invalid bag id."

    if WorldServer.curr == null or WorldServer.curr.instance_manager.death_bag_service == null:
        return "Death Bag service is unavailable."

    var result: Dictionary = WorldServer.curr.instance_manager.death_bag_service.force_sink(bag_id)
    if not bool(result.get("ok", false)):
        return "Death Bag sink failed: %s" % str(result.get("reason", "unknown"))

    return "Death Bag %d is now sunk." % bag_id

extends ChatCommand
## PirateWorld PoC-01 test command.
## Simulates a player death: unsecured inventory becomes a physical Death Bag.

func _init() -> void:
	command_name = "pocbag"
	command_priority = 0
	command_usage = "/pocbag"

func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
	if not args.is_empty():
		return "Usage: " + command_usage
	var player: Player = server_instance.get_player(peer_id)
	if player == null:
		return "Player not found."
	if WorldServer.curr.instance_manager.death_bag_service == null:
		return "Death Bag service is unavailable."
	var result: Dictionary = WorldServer.curr.instance_manager.death_bag_service.spawn_from_player(server_instance, player)
	if not bool(result.get("ok", false)):
		return "Death Bag failed: %s" % str(result.get("reason", "unknown"))
	var bag: Dictionary = result["bag"]
	return "Death Bag %d created. Inventory dropped into the world." % int(bag["bag_id"])

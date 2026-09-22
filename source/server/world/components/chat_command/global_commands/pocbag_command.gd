extends ChatCommand
## PirateWorld PoC-01 test command.
## Simulates a player death: unsecured inventory becomes a physical Death Bag.

func _init() -> void:
\tcommand_name = "pocbag"
\tcommand_priority = 0
\tcommand_usage = "/pocbag"

func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
\tif not args.is_empty():
\t\treturn "Usage: " + command_usage
\tvar player: Player = server_instance.get_player(peer_id)
\tif player == null:
\t\treturn "Player not found."
\tif WorldServer.curr.instance_manager.death_bag_service == null:
\t\treturn "Death Bag service is unavailable."
\tvar result: Dictionary = WorldServer.curr.instance_manager.death_bag_service.spawn_from_player(server_instance, player)
\tif not bool(result.get("ok", false)):
\t\treturn "Death Bag failed: %s" % str(result.get("reason", "unknown"))
\tvar bag: Dictionary = result["bag"]
\treturn "Death Bag %d created. Inventory dropped into the world." % int(bag["bag_id"])

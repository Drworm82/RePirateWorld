extends ChatCommand
## PirateWorld PoC-06 test command.
## Runs the real Player.die() respawn flow while first moving the player's
## carried inventory into a Death Bag. This is intentionally test-only:
## physical doubloon destruction and other final death rules are not applied yet.

func _init() -> void:
	command_name = "pocdeath"
	command_priority = 0
	command_usage = "/pocdeath"


func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
	if args.size() != 1:
		return "Usage: " + command_usage

	var player: Player = server_instance.get_player(peer_id)
	if player == null or player.player_resource == null:
		return "Player not found."

	if player.is_dead:
		return "Player is already dead."

	var death_bag_service = WorldServer.curr.instance_manager.death_bag_service
	if death_bag_service == null:
		return "Death Bag service is unavailable."

	var result: Dictionary = death_bag_service.spawn_from_player(server_instance, player)
	if not bool(result.get("ok", false)):
		return "Death Bag failed: %s" % str(result.get("reason", "unknown"))

	# Mirror the authoritative state transition that normally happens in
	# Character.take_damage() immediately before Player.die().
	player.is_dead = true
	player.stats_component.set_stat(Stat.HEALTH, 0.0)

	# Use the real Player.die() implementation so the normal death screen,
	# countdown and respawn path are exercised. Null means "no killer" for this
	# test and is already handled by LeaderboardService.record_pvp_kill().
	player.die(null)

	var bag: Dictionary = result["bag"]
	return "PoC death triggered. Death Bag %d created. Respawning in 3 seconds." % int(bag["bag_id"])

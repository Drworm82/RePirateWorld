extends DataRequestHandler
## Explicit respawn requested from the Death Screen.
## PoC currently exposes only the map's origin spawn. Future Sleeping Bags / beds
## can add additional validated respawn point IDs without changing the client flow.

func data_request_handler(peer_id: int, instance: ServerInstance, _args: Dictionary) -> Dictionary:
	if not RateLimiter.check(peer_id, &"player.respawn", 2, 1_000):
		return {}

	var player: Player = instance.get_player(peer_id) as Player
	if player == null:
		return {"ok": false, "reason": "player_not_found"}

	return player.respawn_at_origin()

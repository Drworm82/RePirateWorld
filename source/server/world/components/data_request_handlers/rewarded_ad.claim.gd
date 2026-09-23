extends DataRequestHandler

## PoC rewarded-ad claim.
## There is no ad SDK in this prototype: this endpoint simulates a completed
## rewarded ad and grants exactly 1 gold on the authoritative server.
const GOLD_REWARD: int = 1
const WINDOW_MS: int = 10_000
const MAX_CALLS: int = 1


func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	if not RateLimiter.check(peer_id, &"rewarded_ad.claim", MAX_CALLS, WINDOW_MS):
		return {"ok": false, "reason": "rate_limited"}

	var player: PlayerResource = instance.world_server.connected_players.get(peer_id)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}

	var live_player: Player = instance.get_player(peer_id)
	if live_player == null or live_player.is_dead:
		return {"ok": false, "reason": "player_dead"}

	Inventory.add_item(player.inventory, Economy.gold_id(), GOLD_REWARD)
	instance.world_server.database.save_player(player)

	var gold: int = Inventory.count(player.inventory, Economy.gold_id())
	ServerLog.info("[REWARDED_AD] simulated claim peer_id=%d player_id=%d reward=%d gold=%d" % [
		peer_id,
		int(player.player_id),
		GOLD_REWARD,
		gold,
	])

	return {
		"ok": true,
		"reward": GOLD_REWARD,
		"gold": gold,
	}

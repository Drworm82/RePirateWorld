extends RefCounted

## Server-authoritative rewarded-ad economy service.
##
## The PoC uses claim_simulated() because there is no ad provider SDK yet.
## The client never supplies the reward amount: the service owns GOLD_REWARD.
## When a real provider is integrated, the provider's server-verifiable reward
## identifier should be passed to a verified claim method and made single-use.

const GOLD_REWARD: int = 1


func claim_simulated(instance: ServerInstance, peer_id: int) -> Dictionary:
	if instance == null:
		return {"ok": false, "reason": "instance_not_found"}

	var player: PlayerResource = instance.world_server.connected_players.get(peer_id)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}

	var live_player: Player = instance.get_player(peer_id)
	if live_player == null or live_player.is_dead:
		return {"ok": false, "reason": "player_dead"}

	# The reward amount is server-defined. Client arguments are not trusted.
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


## Future real-ad entry point.
##
## reward_id must come from a provider verification path, not arbitrary client
## input. The implementation will reject/reuse-check the provider transaction
## before calling the same economy grant path.
func claim_verified(instance: ServerInstance, peer_id: int, reward_id: String) -> Dictionary:
	if reward_id.is_empty():
		return {"ok": false, "reason": "reward_id_required"}

	# TODO: validate reward_id against the ad provider and persist it as consumed.
	return {"ok": false, "reason": "provider_not_configured"}

extends RefCounted

## Server-authoritative rewarded-ad economy service.
##
## The PoC uses claim_simulated() because there is no ad provider SDK yet.
## The client never supplies the reward amount: the service owns GOLD_REWARD.
## A real provider must supply a server-verifiable reward_id.

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

	return _grant_gold(instance, player, GOLD_REWARD, "simulated")


## Grant a verified provider reward exactly once.
## The provider verification step must establish that reward_id is genuine.
func claim_verified(instance: ServerInstance, peer_id: int, reward_id: String) -> Dictionary:
	if instance == null:
		return {"ok": false, "reason": "instance_not_found"}

	if reward_id.is_empty():
		return {"ok": false, "reason": "reward_id_required"}

	var player: PlayerResource = instance.world_server.connected_players.get(peer_id)
	if player == null:
		return {"ok": false, "reason": "player_not_found"}

	var live_player: Player = instance.get_player(peer_id)
	if live_player == null or live_player.is_dead:
		return {"ok": false, "reason": "player_dead"}

	var db = instance.world_server.database.db
	var created_at_ms := int(Time.get_unix_time_from_system() * 1000.0)
	# Reserve the provider receipt before granting currency. The primary key makes
	# concurrent duplicate claims collapse to one successful insert.
	db.query_with_bindings(
		"INSERT OR IGNORE INTO rewarded_ad_receipts(reward_id, player_id, reward_amount, created_at_ms) VALUES(?, ?, ?, ?);",
		[reward_id, int(player.player_id), GOLD_REWARD, created_at_ms]
	)
	if db.query("SELECT changes() AS changed;") == null:
		return {"ok": false, "reason": "receipt_check_failed"}
	if db.query_result.is_empty() or int(db.query_result[0].get("changed", 0)) != 1:
		ServerLog.warn("[REWARDED_AD] duplicate reward_id=%s peer_id=%d player_id=%d" % [
			reward_id, peer_id, int(player.player_id)
		])
		return {"ok": false, "reason": "reward_already_claimed"}

	var result := _grant_gold(instance, player, GOLD_REWARD, "verified")
	if not bool(result.get("ok", false)):
		return result

	return result


func _grant_gold(instance: ServerInstance, player: PlayerResource, amount: int, source: String) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "invalid_reward"}

	Inventory.add_item(player.inventory, Economy.gold_id(), amount)
	instance.world_server.database.save_player(player)

	var gold: int = Inventory.count(player.inventory, Economy.gold_id())
	ServerLog.info("[REWARDED_AD] %s claim peer_id=%d player_id=%d reward=%d gold=%d" % [
		source,
		int(player.current_peer_id),
		int(player.player_id),
		amount,
		gold,
	])

	return {
		"ok": true,
		"reward": amount,
		"gold": gold,
	}

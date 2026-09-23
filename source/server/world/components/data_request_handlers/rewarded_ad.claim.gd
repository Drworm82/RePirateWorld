extends DataRequestHandler

## PoC rewarded-ad claim.
## There is no ad SDK in this prototype: the service simulates a completed
## rewarded ad and grants exactly 1 gold on the authoritative server.
##
## No client-supplied reward amount is accepted. The economy mutation lives in
## RewardedAdService so a real provider can later replace only the verification
## layer.

func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	var rewarded_ad_service := RewardedAdService.new()
	return rewarded_ad_service.claim_simulated(instance, peer_id)

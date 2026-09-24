# MVP Phase 2 — Ground Combat

## Scope
Phase 2 adds a minimal server-authoritative, turn-based **shared PvE encounter** layer.
The existing real-time weapon/combat system remains intact and is not replaced.

## Encounter
- Goblin-family (goblin_*) and Bandit NPCs start a turn-based encounter when a player reaches their combat trigger.
- One encounter may contain multiple players and multiple NPCs.
- A player entering an NPC already in an encounter joins that encounter.
- A player already in an encounter can bring another valid NPC into it.
- If two separate encounters connect through their participants, the server merges them.
- While an NPC is in an encounter, its normal AI movement/damage path is suspended.
- A player can leave the encounter with Flee without immediately re-targeting that player.

## Turn order
Initial order is derived from speed:
- Player speed = existing MOVE_SPEED / 10, minimum 1.
- Enemy speed = 5.
- Higher value acts first.
- Ties go to the player.
- Newly joined participants are added to the existing turn order.

## Player actions
- Attack: base AD versus enemy armor; the player selects an enemy target.
- Ability: heavy attack at 150% base attack damage; the player selects an enemy target.
- Item: consumes existing item id 1 (Health Potion) and restores up to 20 HP.
- Defend: halves the next incoming damage to that player.
- Flee: removes only that player from the encounter. If no players remain, the encounter ends.

## Enemy AI
Deterministic MVP behavior:
- At or below 30% HP: defend.
- Otherwise: attack a living player using round-robin target selection across the encounter.
- No group AI or complex decision system.

## Damage
The server calculates all damage. Client requests contain the selected action and, for attack/ability, the selected enemy instance id.
The existing Character.take_damage() path is reused so player defeat continues into the existing Death Bag flow.
Enemy defeat reuses the existing HostileNpc.take_damage() and death/reward/loot flow.

## Multiplayer
The encounter is shared by all participating peers. The server owns:
- encounter membership;
- players and NPCs in the encounter;
- turn order and current turn;
- action/target validation;
- damage;
- HP changes;
- victory/defeat/flee results.

The client owns only presentation, target selection, and action requests.

## Validation matrix
| Test | Expected | Status |
|---|---|---|
| Single player / single NPC | Entering a Goblin starts the turn UI | Pending manual test |
| Two players / one NPC | Second player joins the existing encounter | Pending manual test |
| One player / two NPCs | Second NPC joins the same encounter | Pending manual test |
| Two players / two NPCs | Shared encounter contains all four combatants | Pending manual test |
| Encounter merge | Two separate encounters merge when participants connect | Pending manual test |
| Turn order | Turns advance among all living combatants | Pending manual test |
| Target selection | Player can select which NPC to attack | Pending manual test |
| Attack | Selected enemy HP decreases | Pending manual test |
| Ability | Heavy attack differs from basic attack | Pending manual test |
| Item | Potion heals and is consumed | Pending manual test |
| Defend | Next incoming damage is reduced | Pending manual test |
| Flee | Only fleeing player leaves; no immediate re-engagement | Pending manual test |
| Victory | All NPCs die and existing reward/loot flow runs | Pending manual test |
| Defeat | Player death uses existing Death Bag flow | Pending manual test |
| Persistence | Death Bag survives restart after combat death | Pending manual test |

## Closure rule
Phase 2 is NOT considered complete from code inspection alone.
It requires the manual end-to-end tests above on the running Godot server/client build.

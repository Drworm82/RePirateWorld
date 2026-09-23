# MVP Phase 2 — Ground Combat

## Scope
Phase 2 adds a minimal server-authoritative, turn-based 1v1 ground-combat layer.
The existing real-time weapon/combat system remains intact and is not replaced.

## Encounter
- Existing HostileNpc entities whose enemy_type is bandit start the turn-based encounter when a player enters their detection area.
- The Bandit remains the existing world entity and uses its existing visual/resource definition.
- While the turn battle is active, the Bandit AI and movement are suspended.

## Combat rules
### Turn order
Initial order is derived from speed:
- Player speed = existing MOVE_SPEED / 10, minimum 1.
- Bandit MVP speed = 5.
- Higher value acts first.
- Ties go to the player.
This reuses the existing stat system without introducing a new persistent stat solely for the MVP.

### Player actions
- Attack: base AD versus enemy armor.
- Ability: heavy attack at 150% base attack damage.
- Item: consumes existing item id 1 (Health Potion) and restores up to 20 HP.
- Defend: halves the next incoming damage.
- Flee: exits the encounter without reward.

### Enemy AI
Deterministic MVP behavior:
- At or below 30% HP: defend.
- Otherwise: attack.
- No group AI or complex decision system.

### Damage
The server calculates all damage. Client requests contain only the selected action.
The existing Character.take_damage() path is reused so player defeat continues into the existing Death Bag flow.
Enemy defeat reuses the existing HostileNpc.take_damage() and reward/death flow.

## Multiplayer
Each battle is isolated by peer id. The server owns:
- battle state;
- turn;
- action validation;
- damage;
- HP changes;
- victory/defeat/flee result.
The client owns only the presentation and action request UI.

## Validation matrix
| Test | Expected | Status |
|---|---|---|
| Encounter | Entering a Bandit starts the turn UI | Pending manual test |
| Turn order | Player/enemy turns alternate | Pending manual test |
| Attack | Enemy HP decreases | Pending manual test |
| Ability | Heavy attack differs from basic attack | Pending manual test |
| Item | Potion heals and is consumed | Pending manual test |
| Defend | Next incoming damage is reduced | Pending manual test |
| Victory | Bandit dies and existing reward flow runs | Pending manual test |
| Defeat | Player death uses existing Death Bag flow | Pending manual test |
| Persistence | Death Bag survives restart after combat death | Pending manual test |
| Multiplayer isolation | Two players do not share battle state | Pending manual test |

## Closure rule
Phase 2 is NOT considered complete from code inspection alone.
It requires the manual end-to-end tests above on the running Godot server/client build.
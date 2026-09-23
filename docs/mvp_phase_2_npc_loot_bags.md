# MVP Phase 2 — NPC Loot Bags

## Scope

Goblin-family enemies and Bandits now use a temporary NPC loot-bag flow.

This is deliberately separate from the persistent player Death Bag system.

## Lifecycle

1. A Goblin/Bandit dies.
2. Its authored EnemyTypeResource.loot table is rolled once.
3. If loot exists, a temporary NPC Loot Bag is created at the NPC death position.
4. The loot remains server-authoritative while the instance is loaded.
5. Players can open the bag and take individual slots or use Loot All.
6. When empty, the bag is removed.
7. NPC loot is not written to SQLite.
8. The bag disappears when its server instance is unloaded or the server restarts.
9. The dead Goblin/Bandit is not respawned after a short timer. The population is recreated when the map instance is created again.

## Rewards

XP, kill credit, mastery, leaderboard and kill-related progression remain handled by RewardService.

For Phase 2 Goblins/Bandits, loot is excluded from the direct combat reward and placed into the shared NPC Loot Bag instead. Daily loot progress is credited to the player who actually takes the item from the bag.

## Separation from Death Bags

Player Death Bags remain persistent and retain their existing floating/sunk/database lifecycle.

NPC Loot Bags are temporary, in-memory containers with no database schema.

## Future terrain behavior

The current implementation does not assume water, burial or any final-world terrain. The bag has a generic world position and can later be extended with terrain-specific behavior without changing the NPC loot source.

## Respawn policy

Phase 2 intentionally avoids the existing short respawn_delay loop for Goblins/Bandits. A killed NPC is removed from the active population. Re-entry only recreates the NPC if the framework actually unloads and later reloads that map instance; if another player keeps the same instance loaded, the NPC does not respawn merely because one player left.

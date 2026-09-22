# PirateWorld PoC-01 — Death Bag

This branch adds the first PirateWorld-specific persistent world entity.

## What it tests

1. Player A uses `/pocbag`.
2. The server moves A's current inventory into a persistent SQLite Death Bag.
3. The bag appears at A's server-authoritative position.
4. Other clients in the same instance see the bag.
5. F near the bag sends a pickup request.
6. The server validates instance + distance + bag existence.
7. The server transfers the contents to the picker and deletes the bag.
8. The bag is stored in SQLite, so it remains after a world-server restart.

## Test

- Start 1 gateway, 1 master, 1 world and 2 clients.
- Enter both clients as guests.
- Put client A and B in the same instance.
- On client A open chat and run: `/pocbag`
- Verify A's inventory is emptied and a Death Bag appears.
- Move client B next to the bag.
- Press F.
- Verify the bag disappears and B receives the contents.
- Stop/restart the world server before pickup and verify the bag is still present after B reconnects.

## Deliberate PoC limitations

- `/pocbag` simulates death; actual combat/death integration is not part of this first step.
- The visual is temporary debug art.
- Inventory capacity/weight is not modeled yet.
- Bag expiration/sinking is not implemented yet.
- No owner protection or PvP rules are implemented yet.
- Persistence remains SQLite for this PoC; Supabase/PostgreSQL comes later.
